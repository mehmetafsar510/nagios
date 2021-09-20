#!/usr/bin/env bash

# Exit codes
STATE_OK=0
STATE_WARNING=1
STATE_CRITICAL=2
STATE_UNKNOWN=3

type jq >/dev/null 2>&1 || { echo >&2 "I require jq but it's not installed. Aborting."; exit 1; }
type aws >/dev/null 2>&1 || { echo >&2 "I require awscli but it's not installed. Aborting."; exit 1; }
type bc >/dev/null 2>&1 || { echo >&2 "I require bc but it's not installed. Aborting."; exit 1; }
type timeout >/dev/null 2>&1 || type gtimeout >/dev/null 2>&1 || { echo >&2 "I require timeout or gtimeout, but neither is installed. Aborting."; exit 1; }

function usage()
{
cat << EOF
usage: $0 [options]

This script checks AWS cloudwatch metrics. This script is meant for Nagios.

We assume that the binary JQ is installed. Also we assume that the AWS CLI binary is installed and that the
credentials are set up for the user who is executing this script.

OPTIONS:
    -h or --help           Show this message

    -v or --verbose        Optional: Show verbose output

    --profile=x            Optional: Which AWS profile should be used to connect to aws?

    --namespace=x          Required: Enter the AWS namespace where you want to check your metrics for. The "AWS/" prefix can be
                           left out, this is the default namespace prefix. See below. Example: "CloudFront", "EC2" or "Firehose".
                           More information: http://docs.aws.amazon.com/AmazonCloudWatch/latest/DeveloperGuide/aws-namespaces.html

    --namespace-prefix=x   The prefix for the namespace which should be used. By default this is "AWS". If you do not want to use this prefix
                           you should pass this parameter with an empty value.
                           Default: AWS

    --mins=x               Required: Supply the minutes (time window) of which you want to check the AWS metrics. We will fetch the data
                           between NOW-%mins and NOW.

    --region=x             Required: Enter the AWS region which we need to use. For example: "eu-west-1"

    --metric=x             Required: The metric name which you want to check. For example "IncomingBytes"

    --timeout=x            Optional: Specify the max duration in seconds of this script.
                           When the timeout is reached, we will return a UNKNOWN alert status.

    --statistics=x         Required: The statistics which you want to fetch.
                           Possible values: Sum, Average, Maximum, Minimum, SampleCount
                           Default: Average

    --dimensions=x         Required: The dimensions which you want to fetch.
                           Examples:
                              Name=DBInstanceIdentifier,Value=i-1235534
                              Name=DeliveryStreamName,Value=MyStream
                           See also: http://docs.aws.amazon.com/AmazonCloudWatch/latest/monitoring/cloudwatch_concepts.html#dimension-combinations

    --warning=x:x          Required: The warning threshold. You can supply min:max or just max value. Use the format: [@]min:max
                           When no minimal value is given, a default min value of 0 is used.
                           By default we will raise a warning alert when the value is outside the given range. You can start the range
                           with an @ sign to change this logic. We then will alert when the value is inside the range.
                           See below for some examples.

    --critical=x:x         Required: The critical threshold. You can supply min:max or just max value. Use the format: [@]min:max
                           When no minimal value is given, a default min value of 0 is used.
                           By default we will raise a critical alert when the value is outside the given range. You can start the range
                           with an @ sign to change this logic. We then will alert when the value is inside the range.
                           See below for some examples.

    --default="x"          When no data points are returned, it could be because there is no data. By default this script will return
                           the nagios state UNKNOWN. You could also supply a default value here (like 0). In that case we will work
                           with that value when no data points are returned.


    --http_proxy="x"       When you use a proxy to connect to the AWS Cli, you can use this option. See for more information
                           this link: http://docs.aws.amazon.com/cli/latest/userguide/cli-http-proxy.html

    --https_proxy="x"      When you use a proxy to connect to the AWS Cli, you can use this option. See for more information
                           this link: http://docs.aws.amazon.com/cli/latest/userguide/cli-http-proxy.html

    --last-known           When given, we will fetch the last known values up to 20 minutes ago. Cloudwatch metrics are not always up to date.
                           By specifying this option we will walk back in 1 minute steps when no data is known for max 20 minutes.


Example threshold values:

--critical=10
We will raise an alert when the value is < 0 or > 10

--critical=5:10
We will raise an alert when the value is < 5 or > 10

--critical=@5:10
We will raise an alert when the value is >= 5 and <= 10

--critical=~:10
We will raise an alert when the value is > 10 (there is no lower limit)

--critical=10:~
We will raise an alert when the value is < 10 (there is no upper limit)

--critical=10:
(Same as above) We will raise an alert when the value is < 10 (there is no upper limit)

--critical=@1:~
Alert when the value is >= 1. Zero is OK.

--critical=@~:0
Alert when the value is <= 0. So 0.1 or higher is okay.


See for more info: https://www.monitoring-plugins.org/doc/guidelines.html#THRESHOLDFORMAT


#######################
#
# Example usage:
#
# Description here
# $0 --region=eu-west-1 \\
#    --namespace="Firehose" \\
#    --metric="IncomingBytes" \\
#    --statistics="Average" \\
#    --mins=15 \\
#    --dimensions="Name=DeliveryStreamName,Value=Visits-To-Redshift" \\
#    --warning=100 \\
#    --critical=50 \\
#    --verbose
#
########################

EOF
}

#
# Use some fancy colors, see
# @http://stackoverflow.com/a/5947802/1351312
#
function error()
{
	RED='\033[0;31m'
	NC='\033[0m' # No Color
	echo -e "${RED}${1}${NC}";
}

#
# Display verbose output if wanted
#
function verbose
{
    if [[ ${VERBOSE} -eq 1 ]];
    then
        echo $1;
    fi
}

# Check if we should alert for the given value.
# Param 1: threshold. See https://www.monitoring-plugins.org/doc/guidelines.html#THRESHOLDFORMAT
# Param 2: value
#
# The method returns exit code 1 if it should create an ALERT, 0 if the value is ok.
# Use it like this:
#
# shouldAlert "10:15" "9"
# alert=$?
#
# if [[ "${alert}" == "1" ]];
# then
#     echo "ALERT";
# fi
#
# Optionally you can use the variable ${MESSAGE} to get details
function shouldAlert
{
    THRESHOLD=$1
    METRIC_VALUE=$2

    THRESHOLD_MIN=0
    THRESHOLD_MAX=0
    THRESHOLD_INSIDE=0

    MESSAGE="Unknown"
    EXIT=0

    verbose "";
    verbose "--- ${THRESHOLD}, test with value: ${METRIC_VALUE} ---";

    if [[ "-${METRIC_VALUE}-" == "-null-" ]] || [[ "-${METRIC_VALUE}-" == "--" ]];
    then
        UNKNOWN=1;
        MESSAGE="No metric value known.";
        return ${EXIT};
    fi

    # INSIDE mode enabled
    if [[ `echo "${THRESHOLD}" | head -c 1` == "@" ]];
    then
        THRESHOLD_INSIDE=1
        THRESHOLD=$(echo "${THRESHOLD}" | cut -c 2-);
    fi

    if [[ ! "${THRESHOLD}" =~ ^([0-9\.~]+:?|:)([0-9\.~]*)?$ ]];
    then
        error "Invalid THRESHOLD format: ${THRESHOLD}. See https://www.monitoring-plugins.org/doc/guidelines.html#THRESHOLDFORMAT";
        error ""
        usage
        exit ${STATE_UNKNOWN};
    fi

    if [[ "${THRESHOLD}" == *":"* ]];
    then
      THRESHOLD_MIN=$(echo "${THRESHOLD}" | awk -F':' '{print $1}' );
      THRESHOLD_MAX=$(echo "${THRESHOLD}" | awk -F':' '{print $2}' );

      if [[ -z "${THRESHOLD_MIN}" ]];
      then
        THRESHOLD_MIN="~"
      fi

      if [[ -z "${THRESHOLD_MAX}" ]];
      then
        THRESHOLD_MAX="~"
      fi
    else
      THRESHOLD_MIN="0";
      THRESHOLD_MAX="${THRESHOLD}";
    fi

    # Inside mode check?
    if [[ "${THRESHOLD_INSIDE}" == "1" ]];
    then
        verbose "Running in INSIDE mode (alert if value is inside range {${THRESHOLD_MIN} ... ${THRESHOLD_MAX}})";
        if [[ "${THRESHOLD_MAX}" == "~" ]] && [[ "${THRESHOLD_MIN}" == "~" ]];
        then
            MESSAGE="Value is ALWAYS WRONG. Both MIN and MAX threshold are infinity. Value is always between this range!";
            EXIT=1;
        elif [[ "${THRESHOLD_MAX}" == "~" ]];
        then
            if [[ 1 -eq "$(echo "${METRIC_VALUE} < ${THRESHOLD_MIN}" | bc)" ]];
            then
                MESSAGE="VALUE is ok. The value shoud be < ${THRESHOLD_MIN} ";
                EXIT=0;
            else
                MESSAGE="VALUE is too high. The value SHOULD BE < ${THRESHOLD_MIN}";
                EXIT=1;
            fi;
        elif [[ "${THRESHOLD_MIN}" == "~" ]];
        then
            if [[ 1 -eq "$(echo "${METRIC_VALUE} > ${THRESHOLD_MAX}" | bc)" ]];
            then
                MESSAGE="VALUE is ok. The value should be > ${THRESHOLD_MAX}";
                EXIT=0;
            else
                MESSAGE="VALUE is too low. The value SHOULD BE > ${THRESHOLD_MAX}";
                EXIT=1;
            fi;
        elif [[ 1 -ne "$(echo "${METRIC_VALUE} < ${THRESHOLD_MIN}" | bc)" ]] && [[ 1 -ne "$(echo "${METRIC_VALUE} > ${THRESHOLD_MAX}" | bc)" ]];
        then
            MESSAGE="VALUE is wrong. It SHOULD NOT BE inside the range {${THRESHOLD_MIN} ... ${THRESHOLD_MAX}}";
            EXIT=1;
        else
            MESSAGE="VALUE is ok. It is not inside the range {${THRESHOLD_MIN} ... ${THRESHOLD_MAX}}";
            EXIT=0;
        fi
    else
        verbose "Running in OUTSIDE mode (alert if value is outside range {${THRESHOLD_MIN} ... ${THRESHOLD_MAX}})";

        if [[ "${THRESHOLD_MAX}" == "~" ]] && [[ "${THRESHOLD_MIN}" == "~" ]];
        then
            MESSAGE="Value is ALWAYS CORRECT. Both MIN and MAX threshold are infinity. Value is always between this range!";
            EXIT=0;
        elif [[ "${THRESHOLD_MAX}" == "~" ]];
        then
            if [[ 1 -eq "$(echo "${METRIC_VALUE} >= ${THRESHOLD_MIN}" | bc)" ]];
            then
                MESSAGE="VALUE is ok. The value is >= ${THRESHOLD_MIN}";
                EXIT=0;
            else
                MESSAGE="VALUE is too low. The value SHOULD BE >= ${THRESHOLD_MIN}";
                EXIT=1;
            fi;
        elif [[ "${THRESHOLD_MIN}" == "~" ]];
        then
            if [[ 1 -eq "$(echo "${METRIC_VALUE} <= ${THRESHOLD_MAX}" | bc)" ]];
            then
                MESSAGE="VALUE is ok. The value is <= ${THRESHOLD_MAX}";
                EXIT=0;
            else
                MESSAGE="VALUE is too high. The value SHOULD BE <= ${THRESHOLD_MAX}";
                EXIT=1;
            fi;
        elif [[ 1 -eq "$(echo "${METRIC_VALUE} < ${THRESHOLD_MIN}" | bc)" ]] || [[ 1 -eq "$(echo "${METRIC_VALUE} > ${THRESHOLD_MAX}" | bc)" ]];
        then
            MESSAGE="VALUE is wrong. It SHOULD BE inside the range {${THRESHOLD_MIN} ... ${THRESHOLD_MAX}}";
            EXIT=1;
        else
            MESSAGE="VALUE is ok. It is inside the range {${THRESHOLD_MIN} ... ${THRESHOLD_MAX}}";
            EXIT=0;
        fi
    fi

    verbose "Should alert: ${EXIT} - ${MESSAGE}";
    return ${EXIT}
}

#
# Check if there are any parameters given
#
if [ $# -eq 0 ]
then
    usage;
    exit ${STATE_UNKNOWN};
fi

PROFILE=""
NAMESPACE=""
NAMESPACE_PREFIX="AWS"
MINUTES=0
START_TIME=""
END_TIME=""
SECS=0
REGION=""
METRIC=""
STATISTICS="Average"
VERBOSE=0
DIMENSIONS=""
WARNING=""
CRITICAL=""
EXIT=0
WARNING_MIN=0
WARNING_MAX=0
CRITICAL_MIN=0
CRITICAL_MAX=0
UNKNOWN=0
DEFAULT_VALUE=""
HTTP_PROXY=""
HTTPS_PROXY=""
TIMEOUTSEC=0
LASTKNOWN=0

#
# Awesome parameter parsing, see http://stackoverflow.com/questions/192249/how-do-i-parse-command-line-arguments-in-bash
#
for i in "$@"
do
case ${i} in
	--profile=* )
		PROFILE="${i#*=}"
		shift ;
		;;

	--namespace=* )
		NAMESPACE="${i#*=}"
		shift ;
		;;

	--namespace-prefix=* )
		NAMESPACE_PREFIX="${i#*=}"
		shift ;
		;;

	--http_proxy=* )
        HTTP_PROXY="${i#*=}"
        shift ;
        ;;

    --https_proxy=* )
        HTTPS_PROXY="${i#*=}"
        shift ;
        ;;

	--default=* )
		DEFAULT_VALUE="${i#*=}"
		shift ;
		;;

	--mins=* )
	    MINUTES="${i#*=}"
	    shift ;
	    ;;

	--region=* )
		REGION="${i#*=}"
		shift ;
		;;

	--metric=* )
		METRIC="${i#*=}"
		shift ;
		;;

	--statistics=* )
		STATISTICS="${i#*=}"
		shift ;
		;;

	-v | --verbose )
		VERBOSE=1
		shift ;
		;;

	--last-known )
		LASTKNOWN=1
		shift ;
		;;

	--timeout=* )
	   TIMEOUTSEC="${i#*=}"
		shift ;
		;;

	--dimensions=* )
	    DIMENSIONS="${i#*=}"
		shift ;
		;;

	--warning=* )
	    WARNING="${i#*=}"
		shift ;
		;;

	--critical=* )
	    CRITICAL="${i#*=}"
		shift ;
		;;

	help | --help | -h)
		usage ;
		exit ${STATE_UNKNOWN};
		;;

	*)
	    error "Error, unknown parameter \"${i}\" given!";
	    echo "";
		usage ;
		exit ${STATE_UNKNOWN};
		;;
	esac
done

#
# Validation
#

if [[ "${NAMESPACE}" == "" ]];
then
    error "You have to supply a namespace!";
    usage;
    exit ${STATE_UNKNOWN};
fi;

if [[ ${MINUTES} -le 0 ]];
then
    error "You have to supply a time range (minutes)";
    usage;
    exit ${STATE_UNKNOWN};
fi;

if [[ "${REGION}" == "" ]];
then
    error "You have to supply a region!";
    usage;
    exit ${STATE_UNKNOWN};
fi;

if [[ "${METRIC}" == "" ]];
then
    error "You have to supply a metric!";
    usage;
    exit ${STATE_UNKNOWN};
fi;

if [[ "${STATISTICS}" != "SampleCount" ]] && [[ "${STATISTICS}" != "Average" ]] && [[ "${STATISTICS}" != "Sum" ]] && [[ "${STATISTICS}" != "Minimum" ]] && [[ "${STATISTICS}" != "Maximum" ]] ;
then
    error "You have to supply a statistics value";
    error "Possible values: Sum, Average, Maximum, Minimum, SampleCount";
    usage;
    exit ${STATE_UNKNOWN};
fi;

if type timeout >/dev/null 2>&1;
then
    TIMEOUTCMD=timeout;
else
    TIMEOUTCMD=gtimeout;
fi

# when a prefix is given, use that one.
if [[ ! -z "${NAMESPACE_PREFIX}" ]] ;
then
    NAMESPACE="${NAMESPACE_PREFIX}/${NAMESPACE}";
fi

verbose "Namespace: ${NAMESPACE}";
verbose "Metric name: ${METRIC}";
verbose "Period (Seconds): ${SECS}";
verbose "Dimensions: ${DIMENSIONS}";

LASTKNOWN_MINUTES=0
while [[ ${LASTKNOWN_MINUTES} -lt 20 ]] ;
do
    unamestr=`uname`
    STARTMINS=$((MINUTES+1+LASTKNOWN_MINUTES))
    STOPMINS=$((1+LASTKNOWN_MINUTES))

    # Create files to compare against
    if [[ "$unamestr" == 'Darwin' ]]; then
        START_TIME=$(date -v-${STARTMINS}M -u +'%Y-%m-%dT%H:%M:00')
    else
        START_TIME=$(date -u +'%Y-%m-%dT%H:%M:00' -d "-${STARTMINS} minutes")
    fi

    # Create files to compare against
    if [[ "$unamestr" == 'Darwin' ]]; then
        END_TIME=$(date -v-${STOPMINS}M -u +'%Y-%m-%dT%H:%M:00')
    else
        END_TIME=$(date -u +'%Y-%m-%dT%H:%M:00' -d "-${STOPMINS} minutes")
    fi

    SECS=$((60 * ${MINUTES}));
    verbose "---- ATTEMPT $((LASTKNOWN_MINUTES+1)) ----";
    verbose "Start time: ${START_TIME}";
    verbose "Stop time: ${END_TIME}";
    verbose "Minutes window: ${MINUTES}";

    COMMAND="aws cloudwatch get-metric-statistics"
    COMMAND="${COMMAND} --region ${REGION}"
    COMMAND="${COMMAND} --namespace ${NAMESPACE}";
    COMMAND="${COMMAND} --metric-name ${METRIC}";
    COMMAND="${COMMAND} --output json";
    COMMAND="${COMMAND} --start-time ${START_TIME}";
    COMMAND="${COMMAND} --end-time ${END_TIME}";
    COMMAND="${COMMAND} --period ${SECS}";
    COMMAND="${COMMAND} --statistics ${STATISTICS}";

    if [[ "${DIMENSIONS}" != "" ]];
    then
      COMMAND="${COMMAND} --dimensions ${DIMENSIONS}";
    fi

    if [[ "${PROFILE}" != "" ]];
    then
      COMMAND="${COMMAND} --profile ${PROFILE}";
    fi

    verbose "COMMAND: ${COMMAND}";
    verbose "----------------";

    if [[ ! -z "${HTTPS_PROXY}" ]];
    then
        export  HTTPS_PROXY=${HTTPS_PROXY};
    elif [[ ! -z "${HTTP_PROXY}" ]];
    then
      export  HTTP_PROXY=${HTTP_PROXY};
    fi

    # execute the command, optionally with a timeout check
    if [[ ${TIMEOUTSEC} -gt 0 ]];
    then
        COMMAND="${TIMEOUTCMD} ${TIMEOUTSEC} ${COMMAND}";

        RESULT=$(${COMMAND});

        # command timed out ?
        if [[ $? -eq 124 ]];
        then
            verbose "Our command timed out after ${TIMEOUTSEC} seconds. Return status UNKNOWN!";
            echo "UNKNOWN - We failed to retrieve results within ${TIMEOUTSEC} seconds."
            exit ${STATE_UNKNOWN};
        fi
    else
        RESULT=$(${COMMAND});
    fi

    METRIC_VALUE=$(echo ${RESULT} | jq ".Datapoints[0].${STATISTICS}")

    # No data found? Then go back in time
    if [[  "${METRIC_VALUE}" == "null" ]] && [[ ${LASTKNOWN} -eq 1 ]];
    then
        LASTKNOWN_MINUTES=$((LASTKNOWN_MINUTES+1))
        continue;
    fi

    # If here, just stop.
    break;
done


if [[ "${METRIC_VALUE}" == "null" ]] && [[ "${DEFAULT_VALUE}" != "" ]];
then
    verbose "We did not receive any data. Lets work with our default value: ${DEFAULT_VALUE}";
    METRIC_VALUE="${DEFAULT_VALUE}"
fi

if [[ "${METRIC_VALUE}" != "null" ]];
then
    # Make sure that scientific value is converted to floats
    METRIC_VALUE=$(printf '%.9f' "${METRIC_VALUE}")
fi

UNIT=$(echo ${RESULT} | jq -r ".Datapoints[0].Unit")
verbose "Raw result: ${RESULT}";
verbose "Unit: ${UNIT}";
DESCRIPTION=$(echo ${RESULT} | jq ".Label")

verbose "Metric value: ${METRIC_VALUE}";

# Default values
MESSAGE="All ok. "
EXIT=${STATE_OK};

# check if we should alert..
shouldAlert "${CRITICAL}" "${METRIC_VALUE}"
crit=$?

if [[ "${crit}" == "1" ]];
then
    EXIT=${STATE_CRITICAL};
else
    # Critical is fine. Maybe a warning?
    shouldAlert "${WARNING}" "${METRIC_VALUE}"
    warn=$?

    if [[ "${warn}" == "1" ]];
    then
        EXIT=${STATE_WARNING};
    fi
fi

# if there was an unknown reponse at some point exit unknown
if [[ ${UNKNOWN} -eq 1 ]];
then
    EXIT=${STATE_UNKNOWN}
fi

PERFDATA="${METRIC_VALUE}${UNIT};${WARNING};${CRITICAL};0.000000"

BODY="${DIMENSIONS} ${METRIC} (${MINUTES} min ${STATISTICS}): ${METRIC_VALUE} ${UNIT} - ${MESSAGE} | perf=${PERFDATA}"

verbose "${BODY}"

case ${EXIT} in
  ${STATE_OK})
    printf "OK - ${BODY}"
    exit ${EXIT}
    ;;
  ${STATE_WARNING})
    echo "WARNING - ${BODY}"
    exit ${EXIT}
    ;;
  ${STATE_CRITICAL})
    echo "CRITICAL - ${BODY}"
    exit ${EXIT}
    ;;
  *)
    echo "UNKNOWN - ${BODY}"
    exit ${STATE_UNKNOWN};
    ;;
esac
