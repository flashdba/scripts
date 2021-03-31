#!/bin/bash

# slob_harness.sh - Simple harness for running Oracle tests using SLOB
#
# Script Author: flashdba (http://flashdba.com)
# For details of SLOB please see https://kevinclosson.net/slob/
#
# For educational purposes only - no warranty is provided
# Test thoroughly - use at your own risk

SLOB_LOGDIR=logs
SLOB_OUTDIR=AWRs
[ ! -d "$SLOB_OUTDIR" ] && mkdir -p "$SLOB_OUTDIR"
[ ! -d "$SLOB_LOGDIR" ] && mkdir -p "$SLOB_LOGDIR"
[ -f slob.conf ] && cp slob.conf $SLOB_OUTDIR

# Controls for loop - remember that the loop counter controls the number of threads per schema, not the total number of sessions
SLOB_MINCOUNT=1
SLOB_MAXCOUNT=16
SLOB_INCREMENT=2
SLOB_SCHEMAS=4

SLOB_RUNLIST=`seq -s " " $SLOB_MINCOUNT $SLOB_INCREMENT $SLOB_MAXCOUNT`
[ "$1" = "-t" ] && echo "Test Plan: execute with $SLOB_SCHEMAS schemas and thread counts: $SLOB_RUNLIST" && exit 0
echo "Starting $0 at `date +'%F %T'` with $SLOB_SCHEMAS schemas and thread counts: $SLOB_RUNLIST"

for SLOB_THREADS in $SLOB_RUNLIST
do
      SLOB_SESSIONS=$(( $SLOB_THREADS * $SLOB_SCHEMAS ))
      echo "Running SLOB with $SLOB_SESSIONS sessions ($SLOB_SCHEMAS schemas and $SLOB_THREADS threads) at `date +'%F %T'`"
      echo "Executing: sh ./runit.sh -s $SLOB_SCHEMAS -t $SLOB_THREADS" > $SLOB_LOGDIR/runit.$SLOB_SESSIONS.log
      sh ./runit.sh -s $SLOB_SCHEMAS -t $SLOB_THREADS >> $SLOB_LOGDIR/runit.$SLOB_SESSIONS.log 2>&1

      if [ $SLOB_SESSIONS -lt 100 ]; then
            [ -f awr.txt ] && mv awr.txt $SLOB_OUTDIR/awr.00$SLOB_SESSIONS.txt
      elif [ $SLOB_SESSIONS -lt 10 ]; then
            [ -f awr.txt ] && mv awr.txt $SLOB_OUTDIR/awr.0$SLOB_SESSIONS.txt
      else
            [ -f awr.txt ] && mv awr.txt $SLOB_OUTDIR/awr.$SLOB_SESSIONS.txt
      fi
done

echo "$0 completed at `date +'%F %T'`"
exit 0
