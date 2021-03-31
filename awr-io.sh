#!/bin/bash

# awr-io.sh - Simple script to extract IO information from an Oracle AWR report
#
# Author: flashdba (http://flashdba.com)
#
# For educational purposes only - no warranty is provided
# Test thoroughly - use at your own risk

total_iops() {
	TOTAL_IOPS=`grep "Total Requests:" $file | awk '{ print $4 }'`
	return 0
}

total_throughput() {
	TOTAL_THROUGHPUT=`grep "Total (MB):" $file | grep -v Optimized | awk '{ print $4 }'`
	return 0
}

latency() {
	READ_LATENCY=`grep -A 10 "Top 10 Foreground" $file | grep "db file sequential read" | awk '{ print $7 }'`
	return 0
}

if [ "$#" -lt 1 ]; then
	echo "Usage: $0 <awr-text-files>"
	exit 1
fi

for file in $*; do
	total_iops
	total_throughput
	latency
	echo "$file: IOPS = $TOTAL_IOPS      THROUGHPUT: $TOTAL_THROUGHPUT      READ LATENCY = $READ_LATENCY"
done
exit 0
