#!/bin/bash
#
# AWR Parser script : tool for extracting data from Oracle AWR reports
#
# See GitHub repository at https://github.com/flashdba/scripts
#
#  ###########################################################################
#  #                                                                         #
#  # Copyright (C) {2014,2015}  Author: flashdba (http://flashdba.com)       #
#  #                                                                         #
#  # This program is free software; you can redistribute it and/or modify    #
#  # it under the terms of the GNU General Public License as published by    #
#  # the Free Software Foundation; either version 2 of the License, or       #
#  # (at your option) any later version.                                     #
#  #                                                                         #
#  # This program is distributed in the hope that it will be useful,         #
#  # but WITHOUT ANY WARRANTY; without even the implied warranty of          #
#  # MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the           #
#  # GNU General Public License for more details.                            #
#  #                                                                         #
#  # You should have received a copy of the GNU General Public License along #
#  # with this program; if not, write to the Free Software Foundation, Inc., #
#  # 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.             #
#  #                                                                         #
#  ###########################################################################
#
AWRSCRIPT_VERSION="1.01"
AWRSCRIPT_LASTUPDATE="01/12/2014"
#
# Used to parse multiple AWR reports and extract useful information
# The input is an AWR workload repository report **in TEXT format**
# - HTML format reports will be ignored, as will STATSPACK reports
# The output is a CSV file which can be used in Microsoft Excel etc
#
# Usage: ./awr-parser.sh [ -n | -H ] [ -s | -p | -v ] <awr-filename.txt> (wildcards are accepted)
#
#   Script for analyzing multiple AWR reports and extracting useful information
#   Redirect stdout to a CSV file to import into Excel
#   Errors and info are printed to stderr
#
# Options:
#  -h  Help        (print help and version information)
#  -H  Header      (print the header row only and then exit)
#  -n  NoHeader    (do not print the header row in the CSV file)
#  -p  Print       (print AWR report values to screen)
#  -s  Silent      (do not print AWR processing information)
#  -v  Verbose     (show extra AWR processing details)
#  -X  DEBUG       *** HIDDEN OPTION FOR DEBUGGING ***
#
# Return Values:
#   0  Complete Success (all files processed)
#   1  Partial Success  (some files processed)
#   2  Failure          (no files processed)
#
# Example:
#  ./awr-parser.sh -v awrrpt*.txt > output.csv
#
# Version History
#
# 1.00   01/12/2014	flashdba	Initial release

# I have recently learnt that the way I calculate Redo write IOPS/Throughput is incorrect. The Oracle statistic "redo size" does
# not take into account multiplexing of online redo logs, nor does it include the value of "redo wastage". For this reason the
# parsed values for Redo Write IOPS/Throughput and Data Write IOPTS/Throughput are likely to be incorrect. The fix (TODO) will
# be to read the values for Redo from the IOStat section of later AWR reports, or the IO Profile section of >= 11.2.0.4

# A note about the use of bc - the Basic Calculator
# This script uses bc in numerous places so if running via Cygwin ensure bc is installed (it is not part of the default install)
# When reducing the scale of numbers in bc, the default behaviour is simply to drop the extra decimal places insetad of rounding
# To make bc round we have to use a hack where we add half a decimal point and then divide by one
# For example, when reducing to one decimal place we add 0.05 then divide by 1 causing bc to implement the scale reduction
# Alternatively, when reducing to three decimal places we add 0.0005 then divide by 1...it's not pretty, but it works just fine

# Define counters and flags
ERRORCNT=0		# Count number of files where processing errors occurred
FILECNT=0		# Count number of files where processing was attempted
HEADERROW=1		# 0 = No, 1 = Yes, 2 = Only
SILENT=0		# 0 = No, 1 = Yes
PRINT_REPORT_INFO=0	# 0 = No, 1 = Yes
VERBOSE=0		# 0 = No, 1 = Yes
DEBUG=0			# 0 = No, 1 = Yes
# Define constants
EXIT_SUCCESS=0
EXIT_PARTIAL_SUCCESS=1
EXIT_FAILURE=2
AWR_NOTFOUND=0
AWR_PENDING=1
AWR_FOUND=2
# Define section terminators in AWR reports (a string of 61 hyphens)
# Two variables are needed deending on whether we are searching by line or word (see comments on the IFS variable)
OLD_AWR_SECTION_TERMINATOR_BY_WORD="-------------------------------------------------------------"
OLD_AWR_SECTION_TERMINATOR_BY_LINE="          -------------------------------------------------------------"
# In 12c format reports the section terminators are different - there are only 54 hyphens
NEW_AWR_SECTION_TERMINATOR_BY_WORD="------------------------------------------------------"
NEW_AWR_SECTION_TERMINATOR_BY_LINE="                          ---------------------------------------------"
# Define field terminator for use with debugging the contents of variables
ENDCHAR=""

# Define functions for printing messages - echodbg includes call to translate the # character into horizontal tab then expand back to spaces (makes debug easier to read)
echoerr() { echo "Error: $@" 1>&2; let ERRORCNT++; }
echoinf() { [[ "$SILENT" = 1 ]] || echo "Info : ${@}${ENDCHAR}" 1>&2; }
echoprt() { echo "Info : ${@}${ENDCHAR}" 1>&2; }
echovrb() { [[ "$VERBOSE" = 1 ]] && echo "Info : ${@}${ENDCHAR}" 1>&2; }
echodbg() { [[ "$DEBUG" = 1 ]] && echo "Debug: ${@}" | tr '#' '\t' | expand -t 15 1>&2; }
echocsv() { echo "$@"; }

# Function for printing usage information
usage() {
	if [ "$#" -gt 0 ]; then
		echo "Error: $@" 1>&2
	fi
	echo "Usage: $0 [ -n | -H ] [ -s | -p | -v ] <awr-filename.txt> (wildcards are accepted)" 1>&2
	echo "" 1>&2
	echo " Version v${AWRSCRIPT_VERSION} (published on $AWRSCRIPT_LASTUPDATE)"
	echo "" 1>&2
	echo "  Script for analyzing multiple AWR reports and extracting useful information"
	echo "  Redirect stdout to a CSV file to import into Excel" 1>&2
	echo "  Errors and info are printed to stderr" 1>&2
	echo "" 1>&2
	echo "  Options:" 1>&2
	echo "    -h   Help        (print help and version information)" 1>&2
	echo "    -H   Header      (print the header row only and then exit)" 1>&2
	echo "    -n   NoHeader    (do not print the header row in the CSV file)" 1>&2
	echo "    -p   Print       (print AWR report values to screen)" 1>&2
	echo "    -s   Silent      (do not print AWR processing information)" 1>&2
	echo "    -v   Verbose     (show extra AWR processing details)" 1>&2
	echo "" 1>&2
	echo "  Example usage:" 1>&2
	echo "    $0 awr*.txt > awr.csv" 1>&2
	echo "" 1>&2
	exit $EXIT_FAILURE
}

# Function for setting the Internal Field Seperator so that lines read from the AWR file are word-delimited
# This means that spaces, tabs and newlines are all used as field seperators
set_ifs_to_word_delimited() {
	IFS_DELIMITER="WORD"
	IFS=$' \t\n' && echodbg "    Setting IFS to SPACE, TAB and NEWLINE"
}

# Function for setting the Internal Field Seperator so that lines read from the AWR file are line-delimited
# This means that only newlines are used as field seperators, while spaces and tabs are not
set_ifs_to_line_delimited() {
	IFS_DELIMITER="LINE"
	IFS=$'\n' && echodbg "    Setting IFS to NEWLINE"
}

# Function for determining the width and location of columns within each AWR section
# It is passed the header row (a set of hyphens) as input and updates a set of variables accordingly
process_header_row() {
	echodbg "Entering process_header_row() with argument $1"
	# Clear the column variables down
	unset AWRCOL1 AWRCOL2 AWRCOL3 AWRCOL4 AWRCOL5 AWRCOL6 AWRCOL7
	if [ -z "$1" ]; then
		echodbg "process_header_row() called with zero arguments - doing nothing"
		PROCESS_HEADER_ROW="NO_DATA"
		return $EXIT_FAILURE
	else
		# Set IFS to be word delimited
		[[ "$IFS_DELIMITER" = "LINE" ]] && IFS=$' \t\n'
		HEADERROW_ARRAY=($1)
		HEADERROW_COLUMNS="${#HEADERROW_ARRAY[@]}"

		# If necessary change the IFS back to line delimited
		[[ "$IFS_DELIMITER" = "LINE" ]] && IFS=$'\n'

		# If there are less than six words in this header then abandon attempt to process this section
		if [ "$HEADERROW_COLUMNS" -lt "6" ]; then
			echovrb "Failed during process_header_row() because header did not have enough arguments ($HEADERROW_COLUMNS)"
			PROCESS_HEADER_ROW="FAILED"
			return $EXIT_FAILURE
		elif [ "$HEADERROW_COLUMNS" -gt "7" ]; then
			echovrb "Failed during process_header_row() because header had too many arguments ($HEADERROW_COLUMNS)"
			PROCESS_HEADER_ROW="FAILED"
			return $EXIT_FAILURE
		else
			echodbg "Analyzing header row with $HEADERROW_COLUMNS columns"
		fi

		# Variable for use in while loop iterating through columns in header row
		AWRCOLNUM=1
		# Use a counter to keep track of the column locations
		COL_COUNTER=1

		# Begin calculating column locations
		while [ "$AWRCOLNUM" -le "$HEADERROW_COLUMNS" ]; do
			eval AWRCOL${AWRCOLNUM}="${COL_COUNTER}-$(($COL_COUNTER + ${#HEADERROW_ARRAY[${AWRCOLNUM} - 1]} - 1))"
			COL_COUNTER=$(($COL_COUNTER + ${#HEADERROW_ARRAY[${AWRCOLNUM}-1]} + 1))
			let AWRCOLNUM++
		done
		echodbg "Computed column widths: AWRCOL1=$AWRCOL1, AWRCOL2=$AWRCOL2, AWRCOL3=$AWRCOL3, AWRCOL4=$AWRCOL4, AWRCOL5=$AWRCOL5, AWRCOL6=$AWRCOL6, AWRCOL7=$AWRCOL7"
		PROCESS_HEADER_ROW="SUCCESS"
		return $EXIT_SUCCESS
	fi
}

# Function for processing AWR header section and extracting information about the system
process_awr_report() {
	# Read the AWR report looking for key sections containing required information
	# Note that different versions of Oracle have different formats for the AWR header
	# For the first two sections we have to look for a header and then set a flag (to $AWR_FOUND)
	# This flag then triggers specific behaviour over the next defined number of lines
	# For example, the phrase "DB Name" indicates the start of the DB Details section
	# We therefore know that two lines later will contain the DB name, instance num, version etc
	# After this the report is divided up into sections, each of which has its own handler below
	# There are two methods of parsing the data depending on the way it is formatted in the report
	# For one method (e.g. the Profile section) we read each word on the line into its own array element
	# We then pick the data out based on its position relative to the number of words in the line
	# The other method is to pick data out based on start and end character positions (e.g. the Top 5 section)
	# For this method we read the entire line into one array element and parse it using the cut tool
	# Switching between these two methods is a case of changing the Internal Field Seperator (IFS) variable
	# IFS is either set to space, tab and newline (word method) or just newline (character method)

	# Define a set of variables
	ROWCNT=0				# Counter for incrementing as rows of each report are read
	TOP5_LINENUM=0				# Counter for incrementing as wait details in Top 5 section are read
	AWR_FORMAT="Unknown"			# Variable to hold the format version of the AWR report
	AWRLINE_SKIP=0				# When value n is greater than zero the next n non-empty lines will be skipped
	AWRSECTION_SKIP=0			# When value n is greater than zero the next n AWR sections will be skipped
	BAILOUT_COUNTER=0			# Counter for incrementing when searching for the header row of certain sections
	BAILOUT_LIMIT=10			# Threshold beyond which hander will abandon searching for the header row
	FOUND_SYS_DETAILS=$AWR_NOTFOUND		# This is set to AWR_FOUND when the database system details are found
	FOUND_HOST_DETAILS=$AWR_NOTFOUND	# This is set to AWR_FOUND when the host system details are found
	FOUND_TOP5_EVENTS=$AWR_NOTFOUND		# This is set to AWR_FOUND when the Top 5 foreground event details are found (Top 10 in 12c)
	FOUND_FG_WAIT_CLASS=$AWR_NOTFOUND	# This is set to AWR_FOUND when the foreground wait class details are found
	FOUND_FG_WAIT_EVENTS=$AWR_NOTFOUND	# This is set to AWR_FOUND when the foreground wait event details are found
	FOUND_BG_WAIT_EVENTS=$AWR_NOTFOUND	# This is set to AWR_FOUND when the background wait event details are found
	TOTAL_WAIT_TIME=0			# Counter used in wait class section to sum wait times if DB TIME not present in report
	AWR_SECTION="AWRProfile"		# Current section - influences which handler routine will be used to process data
	echodbg "State change AWR_SECTION: reset to Profile"

	# Reset the AWR section terminator varibles to those that match 10g and 11g
	AWR_SECTION_TERMINATOR_BY_WORD="$OLD_AWR_SECTION_TERMINATOR_BY_WORD"
	AWR_SECTION_TERMINATOR_BY_LINE="$OLD_AWR_SECTION_TERMINATOR_BY_LINE"

	# Process the file one line at a time using the read commant - each line will be read into the array AWRLINE and processed
	# For the first section of the AWR report (the Profile) we want each word on a line to live in a seperate element of an array
	# We therefore need to set the IFS (Internal Field Seperator) variable to recognise spaces and tabs as delimiters
	# Later on, when processing other sections, we will change this so that only new lines are recognised as delimiters
	set_ifs_to_word_delimited

	# Begin reading file line by line placing the contents into an array variable
	while read -r -a AWRLINE; do
		# Increment row counter
		let ROWCNT++
		# Remove carriage returns and form feed characters from first element of array to aid in pattern matching later on
		AWRLINE[0]=$(echo ${AWRLINE[0]} | tr -d '\r\f')

		# If line is empty (after removal of control characters) then do not process
		if [ "${#AWRLINE[@]}" = 1 ] && [  -z "${AWRLINE[0]}" ]; then
			echodbg "        Skipping blank line#line $ROWCNT Size=${#AWRLINE[@]} IFS=$IFS_DELIMITER =#${ENDCHAR}${AWRLINE[@]}${ENDCHAR}"
			continue

		# Check for situation where report was generated using SELECT output FROM TABLE(DBMS_WORKLOAD_REPOSITORY.AWR_REPORT_TEXT)
		#   and user did not set heading to 0 resulting in repeated header lines throughout report - skip these lines
		elif [ "${#AWRLINE[@]}" -le 2 ] && [ "${AWRLINE[0]:0:6}" = "OUTPUT" ]; then
			# The next line will be a set of SQLPlus underline characters (usually hyphens) which need to be ignored
			# Therefore increment the counter which controls line skipping
			echodbg "        SQLPlus header at line $ROWCNT - ignoring this plus next line =#${ENDCHAR}${AWRLINE[@]}${ENDCHAR}"
			let AWRLINE_SKIP++
			continue

		# If AWRLINE_SKIP greater than zero then decrement and ignore current line
		elif [ "$AWRLINE_SKIP" -gt 0 ]; then
			echodbg "        Skipping line $ROWCNT due to AWRLINE_SKIP counter ($AWRLINE_SKIP) =#${ENDCHAR}${AWRLINE[@]}${ENDCHAR}"
			let AWRLINE_SKIP--
			continue

		# Check for the standard AWR section terminator (a string of 61 hyphen characters) when IFS is set to word delimited
		elif [ "$IFS_DELIMITER" = "WORD" ] && [ "${AWRLINE[0]}" = "$AWR_SECTION_TERMINATOR_BY_WORD" ]; then
			echodbg "        In $AWR_SECTION#line $ROWCNT Size=${#AWRLINE[@]} IFS=$IFS_DELIMITER =#${ENDCHAR}${AWRLINE[@]}${ENDCHAR}"
			if [ "$AWRSECTION_SKIP" -gt 0 ]; then
				let AWRSECTION_SKIP--
				echodbg "Found AWR section terminator at $ROWCNT - decrementing AWRSECTION_SKIP counter to $AWRSECTION_SKIP"
			elif [ "$AWR_SECTION" != "SearchingForNextSection" ]; then
				echovrb "Found AWR section terminator at $ROWCNT - marking end of section $AWR_SECTION"
				echodbg "State change AWR_SECTION: $AWR_SECTION -> SearchingForNextSection"
				AWR_SECTION="SearchingForNextSection"
				# Switch Internal Field Seperator to only recognise newlines as delimiters
				set_ifs_to_line_delimited
			fi
			continue

		# Check for the standard AWR section terminator (a string of 61 hyphen characters) when IFS is set to line delimited
		elif [ "$IFS_DELIMITER" = "LINE" ] && [ "${AWRLINE[0]:0:71}" = "$AWR_SECTION_TERMINATOR_BY_LINE" ]; then
			echodbg "        In $AWR_SECTION#line $ROWCNT Size=${#AWRLINE[@]} IFS=$IFS_DELIMITER =#${ENDCHAR}${AWRLINE[@]}${ENDCHAR}"
			if [ "$AWRSECTION_SKIP" -gt 0 ]; then
				let AWRSECTION_SKIP--
				echodbg "Found AWR section terminator at $ROWCNT - decrementing AWRSECTION_SKIP counter to $AWRSECTION_SKIP"
			elif [ "$AWR_SECTION" != "SearchingForNextSection" ]; then
				echovrb "Found AWR section terminator at $ROWCNT - marking end of section $AWR_SECTION"
				echodbg "State change AWR_SECTION: $AWR_SECTION -> SearchingForNextSection"
				AWR_SECTION="SearchingForNextSection"
				# Switch Internal Field Seperator to only recognise newlines as delimiters
				set_ifs_to_line_delimited
			fi
			continue

		# If AWRSECTION_SKIP greater than zero then ignore current line
		elif [ "$AWRSECTION_SKIP" -gt 0 ]; then
			echodbg "        Skipping line $ROWCNT due to AWRSECTION_SKIP counter ($AWRSECTION_SKIP) =#${ENDCHAR}${AWRLINE[@]}${ENDCHAR}"
			continue

		# If debug is enabled print the whole line
		else
			echodbg "        In $AWR_SECTION#line $ROWCNT Size=${#AWRLINE[@]} IFS=$IFS_DELIMITER =#${ENDCHAR}${AWRLINE[@]}${ENDCHAR}"
		fi
		# Begin processing code - different sections of the report have different handling routines which are enabled through the AWR_SECTION variable

		##################################################################      Searching For Next Section      ##################################################################
		if [ "$AWR_SECTION" = "SearchingForNextSection" ]; then
			# Routine for searching for the start of the next known section and identifying the correct handler routine
			# This section is also responsible for correctly settings the Internal Field Seperator prior to entering the next handler routine
			case "${AWRLINE[0]:0:40}" in
				"Top 5 Timed Events  "*)
					# Start of the Top 5 Timed Events section found in 10g format AWR reports
					echovrb "Start of 10g Top 5 section found at line $ROWCNT"
					echodbg "State change AWR_SECTION: $AWR_SECTION -> Top5Foreground"
					AWR_SECTION="Top5Foreground"
					# There are three more rows of header to skip before processing this section
					AWRLINE_SKIP=2
					# Reset the bailout counter so that we can search for the header row of this section
					BAILOUT_COUNTER=0
					# Set Internal Field Seperator to read entire line into single array element
					set_ifs_to_line_delimited
					continue
					;;
				"Top 5 Timed Foreground Events"*)
					# Start of the Top 5 Foreground Timed Events section found in 11g format AWR reports
					echovrb "Start of 11g Top 5 section found at line $ROWCNT"
					echodbg "State change AWR_SECTION: $AWR_SECTION -> Top5Foreground"
					AWR_SECTION="Top5Foreground"
					# Set Internal Field Seperator to read entire line into single array element
					set_ifs_to_line_delimited
					# There are five more rows of header to skip before processing this section
					AWRLINE_SKIP=4
					# Reset the bailout counter so that we can search for the header row of this section
					BAILOUT_COUNTER=0
					continue
					;;
				"Top 10 Foreground Events by Total Wait T")
					# Start of the Top 10 Foreground Events section found in newer format 11g and 12c AWR reports
					# To process this we use the same handler as the Top 5 Events found in older 10g and 11g reports
					echovrb "Start of Top 10 section found at line $ROWCNT"
					echodbg "State change AWR_SECTION: $AWR_SECTION -> Top5Foreground"
					AWR_SECTION="Top5Foreground"
					# Set Internal Field Seperator to read entire line into single array element
					set_ifs_to_line_delimited
					# There are four more rows of header to skip before processing this section
					AWRLINE_SKIP=3
					# Reset the bailout counter so that we can search for the header row of this section
					BAILOUT_COUNTER=0
					continue
					;;
				"Cache Sizes"*)
					# Start of the Cache Sizes section
					echovrb "Start of CacheSizes section found at line $ROWCNT"
					echodbg "State change AWR_SECTION: $AWR_SECTION -> CacheSizes"
					AWR_SECTION="CacheSizes"
					# Set Internal Field Seperator to read each word into a different element of the array
					set_ifs_to_word_delimited
					# There is one more row of header to skip before processing this section
					AWRLINE_SKIP=1
					continue
					;;
				"Time Model Statistics  "*)
					# Start of the Time Model Statistics section
					echovrb "Start of Time Model Statistics section found at line $ROWCNT"
					# We only need information from this section if this is a 10g format AWR Report
					if [ "$AWR_FORMAT" != "10" ]; then
						echovrb "Ignoring Time Model Statistics because AWR_FORMAT $AWR_FORMAT not 10"
						AWRSECTION_SKIP=1
						continue
					fi
					echodbg "State change AWR_SECTION: $AWR_SECTION -> TimeModelStatistics"
					AWR_SECTION="TimeModelStatistics"
					# Set Internal Field Seperator to read each word into a different element of the array
					set_ifs_to_word_delimited
					# There are six more rows of header to skip before processing this section
					AWRLINE_SKIP=6
					continue
					;;
				"Operating System Statistics  "*)
					# Start of the Operating System Statistics section
					echovrb "Start of Operating System Stats section found at line $ROWCNT"
					echodbg "State change AWR_SECTION: $AWR_SECTION -> OperatingSystemStats"
					AWR_SECTION="OperatingSystemStats"
					# Set Internal Field Seperator to read each word into a different element of the array
					set_ifs_to_word_delimited
					# Depending on the AWR format there are more rows of header to skip before processing the Operating System Stats section
					if [ "$AWR_FORMAT" = "10" ]; then
						AWRLINE_SKIP=2
					else
						AWRLINE_SKIP=5
					fi
					continue
					;;
				"Wait Class  "*)
					# If this is not 10g then ignore
					if [ "$AWR_FORMAT" != "10" ]; then
						echovrb "Ignoring Wait Class header because AWR_FORMAT $AWR_FORMAT not 10"
						continue
					fi
					# Start of Foreground Wait Class section in 10g versions
					echovrb "Start of Foreground Wait Class section found at line $ROWCNT"
					echodbg "State change AWR_SECTION: $AWR_SECTION -> ForegroundWaitClass"
					AWR_SECTION="ForegroundWaitClass"
					# Set the FOUND_FG_WAIT_CLASS variable to AWR_FOUND for use with 10g calculation of DB Time in post-processing section
					FOUND_FG_WAIT_CLASS=$AWR_FOUND
					# Set Internal Field Seperator to read entire line into single array element
					set_ifs_to_line_delimited
					# There are nine more rows of header to skip before processing the Foreground Wait Class section
					AWRLINE_SKIP=7
					continue
					;;
				"Foreground Wait Class  "*)
					# Start of Foreground Wait Class section in 11g and 12c versions
					echovrb "Start of Foreground Wait Class section found at line $ROWCNT"
					echodbg "State change AWR_SECTION: $AWR_SECTION -> ForegroundWaitClass"
					AWR_SECTION="ForegroundWaitClass"
					# Set Internal Field Seperator to read entire line into single array element
					set_ifs_to_line_delimited
					# There are nine more rows of header to skip before processing the Foreground Wait Class section
					AWRLINE_SKIP=7
					continue
					;;
				"Wait Events  "*)
					# Start of the Foreground Wait Events section in 10g versions
					echovrb "Start of Foreground Wait Events section found at line $ROWCNT"
					echodbg "State change AWR_SECTION: $AWR_SECTION -> ForegroundWaitEvents"
					AWR_SECTION="ForegroundWaitEvents"
					# Set Internal Field Seperator to read entire line into single array element
					set_ifs_to_line_delimited
					# There are nine more rows of header to skip before processing the Foreground Wait Class section
					AWRLINE_SKIP=3
					# Reset the bailout counter so that we can search for the header row of this section
					BAILOUT_COUNTER=0
					continue
					;;
				"Foreground Wait Events  "*)
					# Start of the Foreground Wait Events section in versions later than 10g
					echovrb "Start of Foreground Wait Events section found at line $ROWCNT"
					echodbg "State change AWR_SECTION: $AWR_SECTION -> ForegroundWaitEvents"
					AWR_SECTION="ForegroundWaitEvents"
					# Set Internal Field Seperator to read entire line into single array element
					set_ifs_to_line_delimited
					# There are eight more rows of header to skip before processing the Foreground Wait Class section
					AWRLINE_SKIP=3
					# Reset the bailout counter so that we can search for the header row of this section
					BAILOUT_COUNTER=0
					continue
					;;
				"Background Wait Events  "*)
					# Start of the Background Wait Events section
					echovrb "Start of Background Wait Events section found at line $ROWCNT"
					echodbg "State change AWR_SECTION: $AWR_SECTION -> BackgroundWaitEvents"
					AWR_SECTION="BackgroundWaitEvents"
					# Set Internal Field Seperator to read entire line into single array element
					set_ifs_to_line_delimited
					# Depending on the AWR format there are more rows of header to skip before processing the Background Wait Events section
					AWRLINE_SKIP=3
					# Reset the bailout counter so that we can search for the header row of this section
					BAILOUT_COUNTER=0
					continue
					;;
				"Instance Activity Stats  "*)
					# Start of the Instance Activity Stats section in 10g and 11g format AWR reports
					echovrb "Start of Instance Activity Stats section found at line $ROWCNT"
					echodbg "State change AWR_SECTION: $AWR_SECTION -> InstanceActivityStats"
					AWR_SECTION="InstanceActivityStats"
					# Set Internal Field Seperator to read entire line into single array element
					set_ifs_to_line_delimited
					# Depending on the AWR format there are more rows of header to skip before processing the Instance Activity Stats section
					if [ "$AWR_FORMAT" = "10" ]; then
						AWRLINE_SKIP=2
					else
						AWRLINE_SKIP=3
					fi
					continue
					;;
				"SQL ordered by"*)
					# One of the SQL sections - these should be ignored because punctuation characters in SQL can cause problems
					echodbg "Found start of SQL ordered by section at line $ROWCNT - setting AWRSECTION_SKIP"
					# There are eight more rows of header to skip before processing the Foreground Wait Class section
					let AWRSECTION_SKIP++
					continue
					;;
				"Other Instance Activity Stats  "*)
					# Start of the Other Instance Activity Stats section in 12c format AWR reports
					# Use the normal Instance Activity Stats handler
					echovrb "Start of Other Instance Activity Stats section found at line $ROWCNT"
					echodbg "State change AWR_SECTION: $AWR_SECTION -> InstanceActivityStats"
					AWR_SECTION="InstanceActivityStats"
					# Set Internal Field Seperator to read entire line into single array element
					set_ifs_to_line_delimited
					# Depending on the AWR format there are more rows of header to skip before processing the Instance Activity Stats section
					AWRLINE_SKIP=3
					continue
					;;
				"Instance Activity Stats - Thread Activit")
					# Start of the Instance Activity Stats - Thread Activity section which contains the Log Switches information
					echovrb "Start of Instance Activity Stats - Thread Activity section found at line $ROWCNT"
					echodbg "State change AWR_SECTION: $AWR_SECTION -> ThreadActivity"
					AWR_SECTION="ThreadActivity"
					# Set Internal Field Seperator to read each word into a different element of the array
					set_ifs_to_word_delimited
					# Depending on the AWR format there are more rows of header to skip before processing the Instance Activity Stats section
					AWRLINE_SKIP=3
					continue
					;;
			esac

			# If we make it here, we are searching for the start of a new section and haven't found it, so move on to next line
			continue
		fi

		##################################################################         AWR Profile Section          ##################################################################
		if [ "$AWR_SECTION" = "AWRProfile" ]; then
			# Routine for handling the AWR Profile section of the report
			if [ "$FOUND_SYS_DETAILS" = "$AWR_PENDING" ]; then
				# This line contains the database system details
				FOUND_SYS_DETAILS=$AWR_FOUND
				# Extract data
				PROFILE_DBNAME=${AWRLINE[0]}
				PROFILE_INSTANCENAME=${AWRLINE[2]}
				PROFILE_INSTANCENUM=${AWRLINE[3]}
				if [ "$AWR_FORMAT" = "10" ]; then
					PROFILE_DBVERSION=${AWRLINE[4]}
					PROFILE_CLUSTER=$(echo ${AWRLINE[5]} | cut -c1-1)
					if [ -n "${AWRLINE[6]}" ]; then
						# AWR reports in Oracle version 10 have the hostname at the end of the DB details line
						# The call to tr is necessary to remove the trailing return character
						DB_HOSTNAME=$(echo ${AWRLINE[6]} | tr -d '\r')
						DB_HOST_OS="Unknown"
					else
						echovrb "Unable to find Hostname at end of System Details section"
					fi
					echodbg "Sys Details: DBName=$PROFILE_DBNAME, InstName=$PROFILE_INSTANCENAME, InstNum=$PROFILE_INSTANCENUM, Ver=$PROFILE_DBVERSION, Cluster=$PROFILE_CLUSTER, Hostname=$DB_HOSTNAME, OS=$DB_HOST_OS"
				else
					PROFILE_DBVERSION=${AWRLINE[6]}
					PROFILE_CLUSTER=$(echo ${AWRLINE[7]} | cut -c1-1)
					echodbg "Sys Details: DBName=$PROFILE_DBNAME, InstName=$PROFILE_INSTANCENAME, InstNum=$PROFILE_INSTANCENUM, Ver=$PROFILE_DBVERSION, Cluster=$PROFILE_CLUSTER"
				fi
				continue
			elif [ "$FOUND_HOST_DETAILS" = "$AWR_PENDING" ]; then
				# This line contains the host system details
				FOUND_HOST_DETAILS=$AWR_FOUND
				# Call function to extract data
				DB_HOSTNAME=$(echo "${AWRLINE[0]}"| cut -c1-16|sed -e 's/^[ \t]*//;s/[ \t]*$//')
				DB_HOST_OS=$(echo "${AWRLINE[0]}"| cut -c17-49|sed -e 's/^[ \t]*//;s/[ \t]*$//')
				DB_HOST_MEM=$(echo "${AWRLINE[0]}"| cut -c69-79|sed -e 's/^[ \t]*//;s/[ \t]*$//')
				echodbg "Host Details: Hostname=$DB_HOSTNAME, OS=$DB_HOST_OS, HostMem=$DB_HOST_MEM"
				# Return Internal Field Seperator to reading each word into a different array element
				set_ifs_to_word_delimited
				continue
			fi

			# Examine first two words
			case ${AWRLINE[@]:0:2} in
				"DB Name")
					# Found Database System Details
					[[ "$FOUND_SYS_DETAILS" = "$AWR_FOUND" ]] && continue
					echovrb "Start of Database System details at line $ROWCNT"
					# AWR reports from 11g on have an extra "Startup Time" column in the profile
					if [ "${AWRLINE[@]:7:1}" = "Startup" ]; then
						AWR_FORMAT=11
						# Later on we will discover if it is actually a 12c report rather than 11g as we assume initially
					else
						# Assume this is version 10 format
						AWR_FORMAT=10
					fi
					echovrb "Using AWR Format $AWR_FORMAT"
					# Skip next line as this is part of the header
					AWRLINE_SKIP=1
					FOUND_SYS_DETAILS=$AWR_PENDING
					continue
					;;
				"Host Name")
					# Found Host System Details
					[[ "$FOUND_HOST_DETAILS" = "$AWR_FOUND" ]] && continue
					echovrb "Start of Host System details at line $ROWCNT"
					# Skip next line as this is part of the header
					AWRLINE_SKIP=1
					FOUND_HOST_DETAILS=$AWR_PENDING
					# Set Internal Field Seperator to read full line into first array element
					set_ifs_to_line_delimited
					continue
					;;
				"Begin Snap:")
					# Found details for start of snapshot
					AWR_BEGIN_SNAP=${AWRLINE[2]}
					AWR_BEGIN_TIME="${AWRLINE[3]} ${AWRLINE[4]}"
					echodbg "AWR_BEGIN_SNAP = ${ENDCHAR}$AWR_BEGIN_SNAP${ENDCHAR}"
					echodbg "AWR_BEGIN_TIME = ${ENDCHAR}$AWR_BEGIN_TIME${ENDCHAR}"
					continue
					;;
				"End Snap:")
					# Found details for end of snapshot
					AWR_END_SNAP=${AWRLINE[2]}
					AWR_END_TIME="${AWRLINE[3]} ${AWRLINE[4]}"
					echodbg "AWR_END_SNAP = ${ENDCHAR}$AWR_END_SNAP${ENDCHAR}"
					echodbg "AWR_END_TIME = ${ENDCHAR}$AWR_END_TIME${ENDCHAR}"
					continue
					;;
				"Elapsed:"*)
					# Found details for elapsed time
					AWR_ELAPSED_TIME=$(echo ${AWRLINE[1]} |sed -e 's/,//g')
					echodbg "AWR_ELAPSED_TIME = ${ENDCHAR}$AWR_ELAPSED_TIME${ENDCHAR}"
					# Calculate elapsed time in seconds for use when working out throughput values
					if [ -n "$AWR_ELAPSED_TIME" ]; then
						if [ "$AWR_ELAPSED_TIME" = 0 ]; then
							echovrb "Found zero value for AWR_ELAPSED_TIME"
							AWR_ELAPSED_TIME_SECS=0
						else
							echodbg "Calling BC: echo 'scale=3; $AWR_ELAPSED_TIME * 60' | bc -l"
							AWR_ELAPSED_TIME_SECS=`echo "scale=3; $AWR_ELAPSED_TIME * 60" | bc -l`
						fi
						echodbg "AWR_ELAPSED_TIME_SECS = ${ENDCHAR}$AWR_ELAPSED_TIME_SECS${ENDCHAR}"
						continue
					fi
					;;
				"DB Time:")
					# Found details for DB time
					AWR_DB_TIME=$(echo ${AWRLINE[2]} |sed -e 's/,//g')
					echodbg "AWR_DB_TIME = ${ENDCHAR}$AWR_DB_TIME${ENDCHAR}"
					# If Elapsed Time known then calculate Average Active Sessions (AAS)
					if [ -n "$AWR_ELAPSED_TIME" ]; then
						if [ "$AWR_ELAPSED_TIME" = 0 ]; then
							echoinf "Cannot calculate Average Active Sessions due to zero AWR_ELAPSED_TIME value"
						else
							echodbg "Calling BC: AWR_AAS=echo 'scale=1; $AWR_DB_TIME / $AWR_ELAPSED_TIME' | bc -l"
							AWR_AAS=`echo "scale=1; $AWR_DB_TIME / $AWR_ELAPSED_TIME" | bc -l`
						fi
					else
						echoinf "Found DB Time but not Elapsed Time - unable to calculate Average Active Sessions"
					fi
					echodbg "AWR_ELAPSED_TIME = ${ENDCHAR}$AWR_ELAPSED_TIME${ENDCHAR}"
					continue
					;;
				"Buffer Cache:")
					# Found Cache Sizes section containing database block size
					# The call to tr is necessary to remove the trailing return character
					DB_BLOCK_SIZE=$(echo ${AWRLINE[${#AWRLINE[@]}-1]} | tr -d '\r')
					echodbg "DB_BLOCK_SIZE = ${ENDCHAR}$DB_BLOCK_SIZE${ENDCHAR}"
					continue
					;;
				"Redo size:")
					# Found details for redo bytes per second in the 10g and 11g format AWR reports
					# Because this number is occasionally very large Oracle may print it in scientific notation so we have to convert this if neccessary
					REDO_WRITE_THROUGHPUT=$(echo ${AWRLINE[2]} |sed -e 's/,//g'| sed -e 's/E+/\*10\^/')
					# Convert to MB/sec
					if [ -n "$REDO_WRITE_THROUGHPUT" ]; then
						if [ "$REDO_WRITE_THROUGHPUT" != 0 ]; then
							echodbg "Calling BC: REDO_WRITE_THROUGHPUT=echo 'scale=2; (\$(echo 'scale=6; $REDO_WRITE_THROUGHPUT / 1048576' | bc -l)+0.005)/1' | bc -l"
							REDO_WRITE_THROUGHPUT=`echo "scale=2; ($(echo "scale=6; $REDO_WRITE_THROUGHPUT / 1048576" | bc -l)+0.005)/1" | bc -l`
						fi
					fi
					echodbg "REDO_WRITE_THROUGHPUT = ${ENDCHAR}${REDO_WRITE_THROUGHPUT}${ENDCHAR}"
					continue
					;;
				"Redo size")
					# Found details for redo bytes per second in the 12c format AWR reports
					# Because this number is occasionally very large Oracle may print it in scientific notation so we have to convert this if neccessary
					REDO_WRITE_THROUGHPUT=$(echo ${AWRLINE[3]} |sed -e 's/,//g'| sed -e 's/E+/\*10\^/')
					# Convert to MB/sec
					if [ -n "$REDO_WRITE_THROUGHPUT" ]; then
						if [ "$REDO_WRITE_THROUGHPUT" != 0 ]; then
							echodbg "Calling BC: REDO_WRITE_THROUGHPUT=echo 'scale=2; (\$(echo 'scale=6; $REDO_WRITE_THROUGHPUT / 1048576' | bc -l)+0.005)/1' | bc -l"
							REDO_WRITE_THROUGHPUT=`echo "scale=2; ($(echo "scale=6; $REDO_WRITE_THROUGHPUT / 1048576" | bc -l)+0.005)/1" | bc -l`
						fi
					fi
					echodbg "REDO_WRITE_THROUGHPUT = ${ENDCHAR}${REDO_WRITE_THROUGHPUT}${ENDCHAR}"
					# We now know that this is a 12c format AWR report so update the AWR_FORMAT variable accordingly
					AWR_FORMAT=12
					echovrb "Amending AWR Format to $AWR_FORMAT"
					# Amend the section terminator variables accordingly
					AWR_SECTION_TERMINATOR_BY_WORD="$NEW_AWR_SECTION_TERMINATOR_BY_WORD"
					AWR_SECTION_TERMINATOR_BY_LINE="$NEW_AWR_SECTION_TERMINATOR_BY_LINE"
					continue
					;;
				"Logical reads:")
					# Found details for logical reads per second in the 10g and 11g format AWR reports
					AWR_LOGICAL_READS=$(echo ${AWRLINE[2]} |sed -e 's/,//g')
					echodbg "AWR_LOGICAL_READS = ${ENDCHAR}${AWR_LOGICAL_READS}${ENDCHAR}"
					continue
					;;
				"Logical read")
					# Found details for logical reads per second in the 12c format AWR reports
					AWR_LOGICAL_READS=$(echo ${AWRLINE[3]} |sed -e 's/,//g')
					echodbg "AWR_LOGICAL_READS = ${ENDCHAR}${AWR_LOGICAL_READS}${ENDCHAR}"
					continue
					;;
				"Block changes:")
					# Found details for block changes per second
					AWR_BLOCK_CHANGES=$(echo ${AWRLINE[2]} |sed -e 's/,//g')
					echodbg "AWR_BLOCK_CHANGES = ${ENDCHAR}${AWR_BLOCK_CHANGES}${ENDCHAR}"
					continue
					;;
				"User calls:")
					# Found details for user calls per second
					AWR_USER_CALLS=$(echo ${AWRLINE[2]} |sed -e 's/,//g')
					echodbg "AWR_USER_CALLS = ${ENDCHAR}${AWR_USER_CALLS}${ENDCHAR}"
					continue
					;;
				"Parses:"*)
					# Found details for parses per second in the 10g and 11g format AWR reports
					AWR_PARSES=$(echo ${AWRLINE[1]} |sed -e 's/,//g')
					echodbg "AWR_PARSES = ${ENDCHAR}${AWR_PARSES}${ENDCHAR}"
					continue
					;;
				"Parses"*)
					# Found details for parses per second in the 12c format AWR reports
					AWR_PARSES=$(echo ${AWRLINE[2]} |sed -e 's/,//g')
					echodbg "AWR_PARSES = ${ENDCHAR}${AWR_PARSES}${ENDCHAR}"
					continue
					;;
				"Hard parses:")
					# Found details for hard parses per second in the 10g and 11g format AWR reports
					AWR_HARD_PARSES=$(echo ${AWRLINE[2]} |sed -e 's/,//g')
					echodbg "AWR_HARD_PARSES = ${ENDCHAR}${AWR_HARD_PARSES}${ENDCHAR}"
					continue
					;;
				"Hard parses")
					# Found details for hard parses per second in the 12c format AWR reports
					AWR_HARD_PARSES=$(echo ${AWRLINE[3]} |sed -e 's/,//g')
					echodbg "AWR_HARD_PARSES = ${ENDCHAR}${AWR_HARD_PARSES}${ENDCHAR}"
					continue
					;;
				"Logons:"*)
					# Found details for logons per second
					AWR_LOGONS=$(echo ${AWRLINE[1]} |sed -e 's/,//g')
					echodbg "AWR_LOGONS = ${ENDCHAR}${AWR_LOGONS}${ENDCHAR}"
					continue
					;;
				"Executes:"*)
					# Found details for executes per second in the 10g and 11g format AWR reports
					AWR_EXECUTES=$(echo ${AWRLINE[1]} |sed -e 's/,//g')
					echodbg "AWR_EXECUTES = ${ENDCHAR}${AWR_EXECUTES}${ENDCHAR}"
					continue
					;;
				"Executes"*)
					# Found details for executes per second in the 12c format AWR reports
					AWR_EXECUTES=$(echo ${AWRLINE[2]} |sed -e 's/,//g')
					echodbg "AWR_EXECUTES = ${ENDCHAR}${AWR_EXECUTES}${ENDCHAR}"
					continue
					;;
				"Transactions:"*)
					# Found details for transactions per second
					# The call to tr is necessary to remove the trailing return character
					AWR_TRANSACTIONS=$(echo ${AWRLINE[1]} |sed -e 's/,//g' | tr -d '\r')
					echodbg "AWR_TRANSACTIONS = ${ENDCHAR}${AWR_TRANSACTIONS}${ENDCHAR}"
					continue
					;;
				"Buffer  Hit")
					# Found buffer hit and in-memory sort ratios
					BUFFER_HIT_RATIO=${AWRLINE[3]}
					echodbg "BUFFER_HIT_RATION = ${ENDCHAR}${BUFFER_HIT_RATION}${ENDCHAR}"
					# The call to tr is necessary to remove the trailing return character
					INMEMORY_SORT_RATIO=$(echo ${AWRLINE[7]} | tr -d '\r')
					echodbg "INMEMORY_SORT_RATIO = ${ENDCHAR}${INMEMORY_SORT_RATIO}${ENDCHAR}"
					continue
					;;
				"Instance Efficiency")
					# End of AWR Profile section
					echovrb "End of AWR Profile section found at line $ROWCNT"
					echodbg "State change AWR_SECTION: $AWR_SECTION -> InstanceEfficiency"
					AWR_SECTION="InstanceEfficiency"
					# Set Internal Field Seperator to read each word into a different element of the array
					set_ifs_to_word_delimited
					# Skip the following row which is a header
					AWRLINE_SKIP=1
					continue
					;;
			esac
			continue
		fi	# End of handler routine for profile section of AWR report

		##################################################################         Instance Efficiency          ##################################################################
		if [ "$AWR_SECTION" = "InstanceEfficiency" ]; then
			# Routine for handling the Instance Efficiency section of the report
			# Examine two words
			case ${AWRLINE[@]:0:2} in
				"Buffer Hit")
					# Found buffer hit and in-memory sort ratios
					BUFFER_HIT_RATIO=${AWRLINE[3]}
					echodbg "BUFFER_HIT_RATIO = ${ENDCHAR}${BUFFER_HIT_RATIO}${ENDCHAR}"
					# The call to tr is necessary to remove the trailing return character
					INMEMORY_SORT_RATIO=$(echo ${AWRLINE[7]} | tr -d '\r')
					echodbg "INMEMORY_SORT_RATIO = ${ENDCHAR}${INMEMORY_SORT_RATIO}${ENDCHAR}"
					echovrb "End of Instance Efficiency section found at line $ROWCNT"
					echodbg "State change AWR_SECTION: $AWR_SECTION -> SearchingForNextSection"
					AWR_SECTION="SearchingForNextSection"
					# Switch Internal Field Seperator to only recognise newlines as delimiters
					set_ifs_to_line_delimited
					continue
					;;
				*)
					# Catch all other lines and ignore
					continue
					;;
			esac
		fi

		##################################################################       Top 5 Foreground Events        ##################################################################
		if [ "$AWR_SECTION" = "Top5Foreground" ]; then
			# Routine for handling the Top 5 section of the report
			if [ "$FOUND_TOP5_EVENTS" = "$AWR_NOTFOUND" ]; then
				# We have just begun processing the Top 5 section so first we need to discover the header row (a set of dashes showing the column headings)
				if [ "${AWRLINE[0]:0:6}" = "------" ]; then
					echodbg "Searching for header row... found"
					FOUND_TOP5_EVENTS=$AWR_FOUND
					process_header_row "${AWRLINE[0]}"
					if [ "$PROCESS_HEADER_ROW" != "SUCCESS" ]; then
						echovrb "Unable to determine width of rows in Top 5 / Top 10 Foreground Events section"
						echodbg "State change AWR_SECTION: $AWR_SECTION -> SearchingForNextSection"
						AWR_SECTION="SearchingForNextSection"
						# Switch Internal Field Seperator to only recognise newlines as delimiters
						set_ifs_to_line_delimited
						# Give up trying to process this section
						if [ "$AWR_FORMAT" = "12" ]; then
							AWRLINE_SKIP=10
						else
							AWRLINE_SKIP=5
						fi
					fi
				else
					let BAILOUT_COUNTER++
					if [ "$BAILOUT_COUNTER" -eq "$BAILOUT_LIMIT" ]; then
						echodbg "Failed to find header row (BAILOUT_COUNTER hit threshold = $BAILOUT_COUNTER)"
						echovrb "Unable to determine width of rows in Top 5 / Top 10 Foreground Events section"
						echodbg "State change AWR_SECTION: $AWR_SECTION -> SearchingForNextSection"
						AWR_SECTION="SearchingForNextSection"
						# Switch Internal Field Seperator to only recognise newlines as delimiters
						set_ifs_to_line_delimited
						# Give up trying to process this section
						if [ "$AWR_FORMAT" = "12" ]; then
							AWRLINE_SKIP=10
						else
							AWRLINE_SKIP=5
						fi
					else
						echodbg "Searching for header row... not found (BAILOUT_COUNTER = $BAILOUT_COUNTER)"
					fi
				fi
				continue
			else
				# Start processing the Top 5 section
				let TOP5_LINENUM++
				# If we are past the fifth line of the Top 5 then the section is over so exit the section handler
				# For the Top 10 sections in 12c format reports we do not care about events above the top 5
				if [ "$TOP5_LINENUM" -gt "5" ]; then
					# End of Top 5 section
					echovrb "End of Top 5 section found at line $ROWCNT"
					echodbg "State change AWR_SECTION: $AWR_SECTION -> SearchingForNextSection"
					AWR_SECTION="SearchingForNextSection"
					# Switch Internal Field Seperator to only recognise newlines as delimiters
					set_ifs_to_line_delimited
					continue
				fi
			fi

			# The variables AWRCOLn are set in the process_header_row function call in the preceding if statement
			if [ "${AWRLINE[0]:0:6}" = "DB CPU" -o "${AWRLINE[0]:0:6}" = "CPU tim" ]; then
				# This is the DB CPU line which has a different format to the rest
				echodbg "Top 5 line $TOP5_LINENUM is DB CPU"
				TOP5EVENT_NAME="DB CPU"
				TOP5EVENT_WAITS=""
				TOP5EVENT_TIME=$(echo "${AWRLINE[0]}"| cut -c${AWRCOL3}|sed -e 's/^[ \t]*//;s/[ \t]*$//;s/,//g')
				TOP5EVENT_AVERAGE=""
				TOP5EVENT_PCT_DBTIME=$(echo "${AWRLINE[0]}"| cut -c${AWRCOL5}|sed -e 's/^[ \t]*//;s/[ \t]*$//;s/,//g')
				TOP5EVENT_CLASS=""
			else
				# This is a normal Top 5 line so handle accordingly
				TOP5EVENT_NAME=$(echo "${AWRLINE[0]}"| cut -c${AWRCOL1}|sed -e 's/^[ \t]*//;s/[ \t]*$//')
				TOP5EVENT_WAITS=$(echo "${AWRLINE[0]}"| cut -c${AWRCOL2}|sed -e 's/^[ \t]*//;s/[ \t]*$//;s/,//g')
				TOP5EVENT_TIME=$(echo "${AWRLINE[0]}"| cut -c${AWRCOL3}|sed -e 's/^[ \t]*//;s/[ \t]*$//;s/,//g')
				TOP5EVENT_AVERAGE=$(echo "${AWRLINE[0]}"| cut -c${AWRCOL4}|sed -e 's/^[ \t]*//;s/[ \t]*$//;s/,//g')
				TOP5EVENT_PCT_DBTIME=$(echo "${AWRLINE[0]}"| cut -c${AWRCOL5}|sed -e 's/^[ \t]*//;s/[ \t]*$//;s/,//g')
				TOP5EVENT_CLASS=$(echo "${AWRLINE[0]}"| cut -c${AWRCOL6}|sed -e 's/^[ \t]*//;s/[ \t]*$//')

				if [ -n "$TOP5EVENT_WAITS" ]; then
					# Check the values extracted are valid numbers
					if [[ "$TOP5EVENT_TIME" != *[!0-9,.]* ]]; then
						if [[ "$TOP5EVENT_WAITS" != *[!0-9,]* ]]; then
							if [ "$TOP5EVENT_WAITS" = 0 ]; then
								echovrb "Found zero waits for Top 5 wait event $TOP5EVENT_NAME"
							else
								# See comments in header section for explanation of the way bc is used in calculating the average on the next lines
								echodbg "Calling BC: TOP5EVENT_AVERAGE=echo 'scale=3; (\$(echo 'scale=7; ($TOP5EVENT_TIME / $TOP5EVENT_WAITS) * 1000' | bc -l)+0.0005)/1' | bc -l"
								TOP5EVENT_AVERAGE=`echo "scale=3; ($(echo "scale=7; ($TOP5EVENT_TIME / $TOP5EVENT_WAITS) * 1000" | bc -l)+0.0005)/1" | bc -l`
							fi
						else
							echodbg "Unable to parse Top 5 wait event $TOP5EVENT_NAME due to non-numeric string found in TOP5EVENT_WAITS: $TOP5EVENT_WAITS"
						fi
					else
						echodbg "Unable to parse Top 5 wait event $TOP5EVENT_NAME due to non-numeric string found in TOP5EVENT_TIME: $TOP5EVENT_TIME"
					fi
				fi
			fi
			echodbg "Top 5 Line $TOP5_LINENUM: Name=$TOP5EVENT_NAME, Waits=$TOP5EVENT_WAITS, Time=$TOP5EVENT_TIME, Ave=$TOP5EVENT_AVERAGE, PctDBTime=$TOP5EVENT_PCT_DBTIME, Class=$TOP5EVENT_CLASS"

			# Now place discovered values into the correct array of variables based on TOP5_LINENUM
			#echodbg "eval TOP5EVENT${TOP5_LINENUM}_NAME='$TOP5EVENT_NAME'"
			eval TOP5EVENT${TOP5_LINENUM}_NAME='$TOP5EVENT_NAME'
			#echodbg "eval TOP5EVENT${TOP5_LINENUM}_NAME='$TOP5EVENT_WAITS'"
			eval TOP5EVENT${TOP5_LINENUM}_WAITS='$TOP5EVENT_WAITS'
			#echodbg "eval TOP5EVENT${TOP5_LINENUM}_NAME='$TOP5EVENT_TIME'"
			eval TOP5EVENT${TOP5_LINENUM}_TIME='$TOP5EVENT_TIME'
			#echodbg "eval TOP5EVENT${TOP5_LINENUM}_NAME='$TOP5EVENT_AVERAGE'"
			eval TOP5EVENT${TOP5_LINENUM}_AVERAGE='$TOP5EVENT_AVERAGE'
			#echodbg "eval TOP5EVENT${TOP5_LINENUM}_NAME='$TOP5EVENT_PCT_DBTIME'"
			eval TOP5EVENT${TOP5_LINENUM}_PCT_DBTIME='$TOP5EVENT_PCT_DBTIME'
			#echodbg "eval TOP5EVENT${TOP5_LINENUM}_NAME='$TOP5EVENT_CLASS'"
			eval TOP5EVENT${TOP5_LINENUM}_CLASS='$TOP5EVENT_CLASS'

		fi	# End of handler routine for Top 5 section of AWR report

		##################################################################              Cache Sizes             ##################################################################
		if [ "$AWR_SECTION" = "CacheSizes" ]; then
			# Routine for handling the Cache Sizes section of the report - only called with 12c format reports
			# Examine two words
			case ${AWRLINE[@]:0:2} in
				"Buffer Cache:")
					# Found Cache Sizes section containing database block size
					# The call to tr is necessary to remove the trailing return character
					DB_BLOCK_SIZE=$(echo ${AWRLINE[${#AWRLINE[@]}-1]} | tr -d '\r')
					echodbg "DB_BLOCK_SIZE = ${ENDCHAR}$DB_BLOCK_SIZE${ENDCHAR}"
					continue
					;;
				"Shared Pool"*)
					# End of Cache Sizes section
					echovrb "End of Cache Sizes section found at line $ROWCNT"
					echodbg "State change AWR_SECTION: $AWR_SECTION -> SearchingForNextSection"
					AWR_SECTION="SearchingForNextSection"
					# Switch Internal Field Seperator to only recognise newlines as delimiters
					set_ifs_to_line_delimited
					;;
				*)
					# Catch all other lines and ignore
					continue
					;;
			esac
		fi

		##################################################################         Time Model Statistics        ##################################################################
		if [ "$AWR_SECTION" = "TimeModelStatistics" ]; then
			# Routine for handling the Time Model Statistics section of the report (only called for reports in 10g format)
			# Examine first two words
			case ${AWRLINE[@]:0:2} in
				"DB CPU")
					# Remember to strip out carriage returns and commas
					AWR_DB_CPU=$(echo "${AWRLINE[2]}" | tr -d '\r,')
					AWR_DB_CPU_PCT_DBTIME=$(echo "${AWRLINE[3]}" | tr -d '\r,')
					echodbg "AWR_DB_CPU = ${ENDCHAR}${AWR_DB_CPU}${ENDCHAR}"
					echodbg "AWR_DB_CPU_PCT_DBTIME = ${ENDCHAR}${AWR_DB_CPU_PCT_DBTIME}${ENDCHAR}"
					;;
				*)
					# Ignore other lines
					continue
			esac
			continue
		fi

		##################################################################         Operating System Stats       ##################################################################
		if [ "$AWR_SECTION" = "OperatingSystemStats" ]; then
			# Routine for handling the Operating System Stats section of the report
			# Examine first word
			case ${AWRLINE[@]:0:1} in
				"BUSY_TIME")
					# Remember to strip out carriage returns and commas
					OS_BUSY_TIME=$(echo "${AWRLINE[1]}" | tr -d '\r,')
					echodbg "OS_BUSY_TIME = ${ENDCHAR}${OS_BUSY_TIME}${ENDCHAR}"
					;;
				"IDLE_TIME")
					# Remember to strip out carriage returns and commas
					OS_IDLE_TIME=$(echo "${AWRLINE[1]}" | tr -d '\r,')
					echodbg "OS_IDLE_TIME = ${ENDCHAR}${OS_IDLE_TIME}${ENDCHAR}"
					;;
				"IOWAIT_TIME")
					# Remember to strip out carriage returns and commas
					OS_IOWAIT_TIME=$(echo "${AWRLINE[1]}" | tr -d '\r,')
					echodbg "OS_IOWAIT_TIME = ${ENDCHAR}${OS_IOWAIT_TIME}${ENDCHAR}"
					;;
				"SYS_TIME")
					# Remember to strip out carriage returns and commas
					OS_SYS_TIME=$(echo "${AWRLINE[1]}" | tr -d '\r,')
					echodbg "OS_SYS_TIME = ${ENDCHAR}${OS_SYS_TIME}${ENDCHAR}"
					;;
				"USER_TIME")
					# Remember to strip out carriage returns and commas
					OS_USER_TIME=$(echo "${AWRLINE[1]}" | tr -d '\r,')
					echodbg "OS_USER_TIME = ${ENDCHAR}${OS_USER_TIME}${ENDCHAR}"
					;;
				"OS_CPU_WAIT_TIME")
					# Remember to strip out carriage returns and commas
					OS_CPU_WAIT_TIME=$(echo "${AWRLINE[1]}" | tr -d '\r,')
					echodbg "OS_CPU_WAIT_TIME = ${ENDCHAR}${OS_CPU_WAIT_TIME}${ENDCHAR}"
					;;
				"RSRC_MGR_CPU_WAIT_TIME")
					# Remember to strip out carriage returns and commas
					OS_RSRC_MGR_WAIT_TIME=$(echo "${AWRLINE[1]}" | tr -d '\r,')
					echodbg "OS_RSRC_MGR_WAIT_TIME = ${ENDCHAR}${OS_RSRC_MGR_WAIT_TIME}${ENDCHAR}"
					;;
				"PHYSICAL_MEMORY_BYTES")
					# Reports in 10g format to not show server memory in header section
					if [ "$AWR_FORMAT" = "10" ]; then
						# Convert from bytes to GB remembering to strip out carriage returns and commas
						echodbg "Calling BC: DB_HOST_MEM=echo \"scale=3; $(echo ${AWRLINE[1]} | tr -d '\r,') / 1073741824\" | bc -l"
						DB_HOST_MEM=`echo "scale=3; $(echo ${AWRLINE[1]} | tr -d '\r,') / 1073741824" | bc -l`
						echodbg "DB_HOST_MEM = ${ENDCHAR}${DB_HOST_MEM}${ENDCHAR}"
					fi
					;;
				"NUM_CPUS")
					# Remember to strip out carriage returns and commas
					DB_NUM_CPUS=$(echo "${AWRLINE[1]}" | tr -d '\r,')
					echodbg "DB_NUM_CPUS = ${ENDCHAR}${DB_NUM_CPUS}${ENDCHAR}"
					;;
				*)
					# Ignore other lines
					continue
			esac
			continue
		fi

		##################################################################         Foreground Wait Class        ##################################################################
		if [ "$AWR_SECTION" = "ForegroundWaitClass" ]; then
			# Routine for handling the Foreground Wait Class section of the report
			# For 10g AWR format this includes a tracker for totalling wait time in order to calculate DB CPU
			case ${AWRLINE[0]:0:20} in
				"Wait Class"*)
					# Still in the header so ignore and carry on to the next line
					echodbg "Still in section header - ignore"
					continue
					;;
				"--------"*)
					# The header row - call process_header_row function to find widths of columns
					process_header_row "${AWRLINE[0]}"
					if [ "$PROCESS_HEADER_ROW" != "SUCCESS" ]; then
						echovrb "Unable to determine width of rows in Foreground Wait Class section"
						echodbg "State change AWR_SECTION: $AWR_SECTION -> SearchingForNextSection"
						AWR_SECTION="SearchingForNextSection"
						# Switch Internal Field Seperator to only recognise newlines as delimiters
						set_ifs_to_line_delimited
						# Give up trying to process this section
						let AWRSECTION_SKIP++
					fi
					continue
					;;
				"DB CPU"*)
					# This string will only be found in 11g and above AWR reports
					# The variables AWRCOLn are set in the process_header_row function call earlier in the handler
					AWR_DB_CPU=$(echo "${AWRLINE[0]}"| cut -c${AWRCOL4}|sed -e 's/^[ \t]*//;s/[ \t]*$//;s/,//g')
					AWR_DB_CPU_PCT_DBTIME=$(echo "${AWRLINE[0]}"| cut -c${AWRCOL6}|sed -e 's/^[ \t]*//;s/[ \t]*$//;s/,//g')
					echovrb "Processing Foreground Wait Class DB CPU"
					echodbg "AWR_DB_CPU = ${ENDCHAR}${AWR_DB_CPU}${ENDCHAR}"
					echodbg "AWR_DB_CPU_PCT_DBTIME = ${ENDCHAR}${AWR_DB_CPU_PCT_DBTIME}${ENDCHAR}"
					continue
					;;
				"Administrative"*)
					WAIT_CLASS_NAME="ADMIN"
					echovrb "Processing Foreground Wait Class Administrative"
					;;
				"Application"*)
					WAIT_CLASS_NAME="APPLN"
					echovrb "Processing Foreground Wait Class Application"
					;;
				"Cluster"*)
					WAIT_CLASS_NAME="CLSTR"
					echovrb "Processing Foreground Wait Class Cluster"
					;;
				"Commit"*)
					WAIT_CLASS_NAME="COMMT"
					echovrb "Processing Foreground Wait Class Commit"
					;;
				"Concurrency"*)
					WAIT_CLASS_NAME="CNCUR"
					echovrb "Processing Foreground Wait Class Concurrency"
					;;
				"Configuration"*)
					WAIT_CLASS_NAME="CONFG"
					echovrb "Processing Foreground Wait Class Configuration"
					;;
				"Network"*)
					WAIT_CLASS_NAME="NETWK"
					echovrb "Processing Foreground Wait Class Network"
					;;
				"Other"*)
					WAIT_CLASS_NAME="OTHER"
					echovrb "Processing Foreground Wait Class Other"
					;;
				"Scheduler"*)
					WAIT_CLASS_NAME="SCHED"
					echovrb "Processing Foreground Wait Class Scheduler"
					;;
				"User I/O"*)
					WAIT_CLASS_NAME="USRIO"
					echovrb "Processing Foreground Wait Class User I/O"
					;;
				"System I/O"*)
					WAIT_CLASS_NAME="SYSIO"
					echovrb "Processing Foreground Wait Class System I/O"
					;;
				*)
					# One of the other wait classes that we do not explicitely capture
					echovrb "Ignoring wait class: ${AWRLINE[0]:0:20}"
					# If this is 10g add to the running total for calculating DB Time
					if [ "$AWR_FORMAT" = '10' ]; then
						# Attempt to extract value for total wait time
						# The variables AWRCOLn are set in the process_header_row function call earlier in the handler
						TOTAL_WAIT_TIME_TMP=$(echo '${AWRLINE[0]}'| cut -c${AWRCOL4}|sed -e 's/^[ \t]*//;s/[ \t]*$//;s/,//g')
						echodbg "TOTAL_WAIT_TIME_TMP = ${ENDCHAR}${TOTAL_WAIT_TIME_TMP}${ENDCHAR}"
						# First check that the value we extract is actually a number, otherwise things will go bad when we inject it into the calculation below
						if [ -n "$TOTAL_WAIT_TIME_TMP" ]; then
							if [[ "$TOTAL_WAIT_TIME_TMP" != *[!0-9,]* ]]; then
								echodbg "Calling BC: TOTAL_WAIT_TIME=echo 'scale=3; $TOTAL_WAIT_TIME + $TOTAL_WAIT_TIME_TMP' | bc -l"
								TOTAL_WAIT_TIME=`echo "scale=3; $TOTAL_WAIT_TIME + $TOTAL_WAIT_TIME_TMP" | bc -l`
								echodbg "TOTAL_WAIT_TIME = ${ENDCHAR}${TOTAL_WAIT_TIME}${ENDCHAR}"
							else
								# Value extracted was non-blank but non-numeric
								echodbg "Unable to determine TOTAL_WAIT_TIME from non-numeric string: $TOTAL_WAIT_TIME_TMP"
							fi
						else
							# Value extracted was blank
							echodbg "Unable to determine TOTAL_WAIT_TIME from empty variable TOTAL_WAIT_TIME_TMP"
						fi
						unset TOTAL_WAIT_TIME_TMP
					fi
					continue
					;;
			esac

			# Get the values for number of waits and wait time, then calculate average wait time
			# The format of this section is slightly different between releases 10 and 11
			# For 10g we keep a running total to calculate the percentage of DB Time, for 11g we just read it from the report
			# The 12c format matches the 11g format for once, so we reuse the same code
			# The variables AWRCOLn are set in the process_header_row function call earlier in the handler
			WAIT_CLASS_NUM_WAITS=$(echo "${AWRLINE[0]}"| cut -c${AWRCOL2}|sed -e 's/^[ \t]*//;s/[ \t]*$//;s/,//g')
			WAIT_CLASS_WAIT_TIME=$(echo "${AWRLINE[0]}"| cut -c${AWRCOL4}|sed -e 's/^[ \t]*//;s/[ \t]*$//;s/,//g')
			if [ "$AWR_FORMAT" = '10' ]; then
				if [ -n "$WAIT_CLASS_WAIT_TIME" ]; then
					echodbg "Calling BC: TOTAL_WAIT_TIME=echo 'scale=3; $TOTAL_WAIT_TIME + $WAIT_CLASS_WAIT_TIME' | bc -l"
					TOTAL_WAIT_TIME=`echo "scale=3; $TOTAL_WAIT_TIME + $WAIT_CLASS_WAIT_TIME" | bc -l`
					echodbg "TOTAL_WAIT_TIME = ${ENDCHAR}${TOTAL_WAIT_TIME}${ENDCHAR}"
				fi
				unset WAIT_CLASS_PCT_DBTIME
			elif [ "$AWR_FORMAT" = '11' ] || [ "$AWR_FORMAT" = '12' ]; then
				WAIT_CLASS_PCT_DBTIME=$(echo "${AWRLINE[0]}"| cut -c${AWRCOL6}|sed -e 's/^[ \t]*//;s/[ \t]*$//;s/,//g')
			else
				# Set WAIT_CLASS_WAIT_TIME to zero to avoid breaking the call to BC below
				WAIT_CLASS_WAIT_TIME=0
			fi
			# Calculate average wait - but first check that the number of waits is greater than zero
			if [ -n "$WAIT_CLASS_NUM_WAITS" ]; then
				if [ "$WAIT_CLASS_NUM_WAITS" != "0" ]; then
					# See comments in header section for explanation of the way bc is used in calculating the average values below
					echodbg "Calling BC: WAIT_CLASS_AVEWAIT=echo 'scale=3; (\$(echo 'scale=7; ($WAIT_CLASS_WAIT_TIME / $WAIT_CLASS_NUM_WAITS) * 1000' | bc -l)+0.0005)/1' | bc -l"
					WAIT_CLASS_AVEWAIT=`echo "scale=3; ($(echo "scale=7; ($WAIT_CLASS_WAIT_TIME / $WAIT_CLASS_NUM_WAITS) * 1000" | bc -l)+0.0005)/1" | bc -l`
				else
					WAIT_CLASS_AVEWAIT=0
				fi
			else
				unset WAIT_CLASS_AVEWAIT
			fi

			echodbg "Foreground Wait Class $WAIT_CLASS_NAME: Waits=$WAIT_CLASS_NUM_WAITS, Time=$WAIT_CLASS_WAIT_TIME, PctDBTime=$WAIT_CLASS_PCT_DBTIME, Ave=$WAIT_CLASS_AVEWAIT"

			# Now place discovered values into the correct array of variables based on the WAIT_CLASS_NAME
			eval WCLASS_${WAIT_CLASS_NAME}_NUM_WAITS='$WAIT_CLASS_NUM_WAITS'
			eval WCLASS_${WAIT_CLASS_NAME}_WAIT_TIME='$WAIT_CLASS_WAIT_TIME'
			[[ -n "$WAIT_CLASS_AVEWAIT" ]] && eval WCLASS_${WAIT_CLASS_NAME}_AVEWAIT='$WAIT_CLASS_AVEWAIT'
			[[ -n "$WAIT_CLASS_PCT_DBTIME" ]] && eval WCLASS_${WAIT_CLASS_NAME}_PCT_DBTIME='$WAIT_CLASS_PCT_DBTIME'

		fi	# End of handler routine for Foreground Wait Class section of AWR report

		##################################################################         Foreground Wait Events       ##################################################################
		if [ "$AWR_SECTION" = "ForegroundWaitEvents" ]; then
			# Routine for handling the Foreground Wait Events section of the report
			# The format of this section is slightly different between releases 10 and 11

		if [ "$FOUND_FG_WAIT_EVENTS" = "$AWR_NOTFOUND" ]; then
			# We have just begun processing the Foreground Wait Events section so first we need to discover the header row (a set of dashes showing the column headings)
			if [ "${AWRLINE[0]:0:6}" = "------" ]; then
				echodbg "Searching for header row... found"
				FOUND_FG_WAIT_EVENTS=$AWR_FOUND
				process_header_row "${AWRLINE[0]}"
				if [ "$PROCESS_HEADER_ROW" != "SUCCESS" ]; then
					echovrb "Unable to determine width of rows in Foreground Wait Events section"
					echodbg "State change AWR_SECTION: $AWR_SECTION -> SearchingForNextSection"
					AWR_SECTION="SearchingForNextSection"
					# Switch Internal Field Seperator to only recognise newlines as delimiters
					set_ifs_to_line_delimited
					# Give up trying to process this section
					if [ "$AWR_FORMAT" = "12" ]; then
						AWRLINE_SKIP=10
					else
						AWRLINE_SKIP=5
					fi
				fi
			else
				let BAILOUT_COUNTER++
				if [ "$BAILOUT_COUNTER" -eq "$BAILOUT_LIMIT" ]; then
					echodbg "Failed to find header row (BAILOUT_COUNTER hit threshold = $BAILOUT_COUNTER)"
					echovrb "Unable to determine width of rows in Foreground Wait Events section"
					echodbg "State change AWR_SECTION: $AWR_SECTION -> SearchingForNextSection"
					AWR_SECTION="SearchingForNextSection"
					# Switch Internal Field Seperator to only recognise newlines as delimiters
					set_ifs_to_line_delimited
					# Give up trying to process this section
					if [ "$AWR_FORMAT" = "12" ]; then
						AWRLINE_SKIP=10
					else
						AWRLINE_SKIP=5
					fi
				else
					echodbg "Searching for header row... not found (BAILOUT_COUNTER = $BAILOUT_COUNTER)"
				fi
			fi
			continue
		fi

			# Start processing the section
			case ${AWRLINE[0]:0:26} in
				"cell multiblock physical r")
					[[ "$EXADATA_FLAG" = "N" ]] && echovrb "Found evidence of Exadata system"
					EXADATA_FLAG="Y"
					;;
				"cell single block physical")
					[[ "$EXADATA_FLAG" = "N" ]] && echovrb "Found evidence of Exadata system"
					EXADATA_FLAG="Y"
					;;
				"db file sequential read"*)
					WAIT_NAME="DFSR"
					;;
				"db file scattered read"*)
					WAIT_NAME="DFXR"
					;;
				"direct path read"*)
					# This could be either direct path read or direct path read temp - so check and act accordingly
					if [ "${AWRLINE[0]:0:21}" = "direct path read temp" ]; then
						WAIT_NAME="DPRT"
					else
						WAIT_NAME="DPRD"
					fi
					;;
				"direct path write"*)
					# This could be either direct path write or direct path write temp - so check and act accordingly
					if [ "${AWRLINE[0]:0:22}" = "direct path write temp" ]; then
						WAIT_NAME="DPWT"
					else
						WAIT_NAME="DPWR"
					fi
					;;
				"log file sync"*)
					WAIT_NAME="LFSY"
					;;
				*)
					# Catch all other lines and set WAIT_NAME to be blank
					WAIT_NAME=""
					continue
					;;
			esac

			# Now check WAIT_TIME and if set begin handling the line
			if [ -n "$WAIT_NAME" ]; then
				if [ "$AWR_FORMAT" = "10" ]; then
					WAIT_NUM_WAITS=$(echo "${AWRLINE[0]}"| cut -c${AWRCOL2}|sed -e 's/^[ \t]*//;s/[ \t]*$//;s/,//g')
					WAIT_TIME=$(echo "${AWRLINE[0]}"| cut -c${AWRCOL4}|sed -e 's/^[ \t]*//;s/[ \t]*$//;s/,//g')
					# No %DB Time column present in 10g reports - calculate value manually then round to one decimal place
					if [ -n "$AWR_DB_TIME" ] && [ "$AWR_DB_TIME" != "0" ]; then
						# See comments in header section for explanation of the way bc is used in calculating the average on the next line
						echodbg "Calling BC: WAIT_PCT_DBTIME=echo 'scale=1; (\$(echo 'scale=5; ($WAIT_TIME/($AWR_DB_TIME*60))*100' | bc -l)+0.05)/1' | bc -l"
						WAIT_PCT_DBTIME=`echo "scale=1; ($(echo "scale=5; ($WAIT_TIME/($AWR_DB_TIME*60))*100" | bc -l)+0.05)/1" | bc -l`
					else
						WAIT_PCT_DBTIME=""
					fi
				elif [ "$AWR_FORMAT" = "11" ] || [ "$AWR_FORMAT" = "12" ]; then
					WAIT_NUM_WAITS=$(echo "${AWRLINE[0]}"| cut -c${AWRCOL2}|sed -e 's/^[ \t]*//;s/[ \t]*$//;s/,//g')
					WAIT_TIME=$(echo "${AWRLINE[0]}"| cut -c${AWRCOL4}|sed -e 's/^[ \t]*//;s/[ \t]*$//;s/,//g')
					WAIT_PCT_DBTIME=$(echo "${AWRLINE[0]}"| cut -c${AWRCOL7}|sed -e 's/^[ \t]*//;s/[ \t]*$//;s/,//g')
				else
					# Set WAIT_TIME to zero to avoid breaking call to BC below
					WAIT_TIME=0
				fi
				# Calculate the average wait time in milliseconds with three decimal places
				if [ -n "$WAIT_NUM_WAITS" ] && [ "$WAIT_NUM_WAITS" != "0" ]; then
					# See comments in header section for explanation of the way bc is used in calculating the average on the next line
					echodbg "Calling BC: WAIT_AVERAGE=echo 'scale=3; (\$(echo 'scale=7; ($WAIT_TIME / $WAIT_NUM_WAITS) * 1000' | bc -l)+0.0005)/1' | bc -l"
					WAIT_AVERAGE=`echo "scale=3; ($(echo "scale=7; ($WAIT_TIME / $WAIT_NUM_WAITS) * 1000" | bc -l)+0.0005)/1" | bc -l`
				else
					WAIT_AVERAGE=""
				fi

				echodbg "Foreground Wait Events $WAIT_NAME: Waits=$WAIT_NUM_WAITS, Time=$WAIT_TIME, PctDBTime=$WAIT_PCT_DBTIME, Ave=$WAIT_AVERAGE"

				# Set variable based on name of wait
				eval WAIT_${WAIT_NAME}_WAITS='$WAIT_NUM_WAITS'
				eval WAIT_${WAIT_NAME}_TIME='$WAIT_TIME'
				eval WAIT_${WAIT_NAME}_AVERAGE='$WAIT_AVERAGE'
				eval WAIT_${WAIT_NAME}_PCT_DBTIME='$WAIT_PCT_DBTIME'
			fi
			continue
		fi	# End of handler routine for Foreground Wait Events section of AWR report

		##################################################################         Background Wait Events       ##################################################################
		if [ "$AWR_SECTION" = "BackgroundWaitEvents" ]; then
			# Routine for handling the Background Wait Events section of the report
			# The format of this section is slightly different between releases 10 and 11

		if [ "$FOUND_BG_WAIT_EVENTS" = "$AWR_NOTFOUND" ]; then
			# We have just begun processing the Background Wait Events section so first we need to discover the header row (a set of dashes showing the column headings)
			if [ "${AWRLINE[0]:0:6}" = "------" ]; then
				echodbg "Searching for header row... found"
				FOUND_BG_WAIT_EVENTS=$AWR_FOUND
				process_header_row "${AWRLINE[0]}"
				if [ "$PROCESS_HEADER_ROW" != "SUCCESS" ]; then
					echovrb "Unable to determine width of rows in Background Wait Events section"
					echodbg "State change AWR_SECTION: $AWR_SECTION -> SearchingForNextSection"
					AWR_SECTION="SearchingForNextSection"
					# Switch Internal Field Seperator to only recognise newlines as delimiters
					set_ifs_to_line_delimited
					# Give up trying to process this section
					if [ "$AWR_FORMAT" = "12" ]; then
						AWRLINE_SKIP=10
					else
						AWRLINE_SKIP=5
					fi
				fi
			else
				let BAILOUT_COUNTER++
				if [ "$BAILOUT_COUNTER" -eq "$BAILOUT_LIMIT" ]; then
					echodbg "Failed to find header row (BAILOUT_COUNTER hit threshold = $BAILOUT_COUNTER)"
					echovrb "Unable to determine width of rows in Background Wait Events section"
					echodbg "State change AWR_SECTION: $AWR_SECTION -> SearchingForNextSection"
					AWR_SECTION="SearchingForNextSection"
					# Switch Internal Field Seperator to only recognise newlines as delimiters
					set_ifs_to_line_delimited
					# Give up trying to process this section
					if [ "$AWR_FORMAT" = "12" ]; then
						AWRLINE_SKIP=10
					else
						AWRLINE_SKIP=5
					fi
				else
					echodbg "Searching for header row... not found (BAILOUT_COUNTER = $BAILOUT_COUNTER)"
				fi
			fi
			continue
		fi

			# Start processing the section
			case ${AWRLINE[0]:0:26} in
				"db file parallel write"*)
					WAIT_NAME="DFPW"
					;;
				"log file parallel write"*)
					WAIT_NAME="LFPW"
					;;
				"log file sequential read"*)
					WAIT_NAME="LFSR"
					;;
				"log file parallel write"*)
					WAIT_NAME="LFPW"
					;;
				"LNS wait on SENDREQ"*)
					echovrb "Found evidence of Data Guard in use on this system"
					DATA_GUARD_FLAG="Y"
					;;
				*)
					# Catch all other lines and set WAIT_NAME to be blank
					WAIT_NAME=""
					;;
			esac
			# Now check WAIT_TIME and if set begin handling the line
			if [ -n "$WAIT_NAME" ]; then
				if [ "$AWR_FORMAT" = "10" ]; then
					WAIT_NUM_WAITS=$(echo "${AWRLINE[0]}"| cut -c${AWRCOL2}|sed -e 's/^[ \t]*//;s/[ \t]*$//;s/,//g')
					WAIT_TIME=$(echo "${AWRLINE[0]}"| cut -c${AWRCOL4}|sed -e 's/^[ \t]*//;s/[ \t]*$//;s/,//g')
					# No %BG Time column present in 10g reports - cannot calculate manually so leave blank
					WAIT_PCT_DBTIME=""
				elif [ "$AWR_FORMAT" = "11" ] || [ "$AWR_FORMAT" = "12" ]; then
					WAIT_NUM_WAITS=$(echo "${AWRLINE[0]}"| cut -c${AWRCOL2}|sed -e 's/^[ \t]*//;s/[ \t]*$//;s/,//g')
					WAIT_TIME=$(echo "${AWRLINE[0]}"| cut -c${AWRCOL4}|sed -e 's/^[ \t]*//;s/[ \t]*$//;s/,//g')
					WAIT_PCT_DBTIME=$(echo "${AWRLINE[0]}"| cut -c${AWRCOL7}|sed -e 's/^[ \t]*//;s/[ \t]*$//;s/,//g')
				else
					# Set WAIT_TIME to zero to avoid breaking call to BC below
					WAIT_TIME=0
				fi

				# Calculate the average wait time in milliseconds with three decimal places
				if [ -n "$WAIT_NUM_WAITS" ] && [ "$WAIT_NUM_WAITS" != "0" ]; then
					# See comments in header section for explanation of the way bc is used in calculating the average on the next line
					echodbg "Calling BC: WAIT_AVERAGE=echo 'scale=3; (\$(echo 'scale=7; ($WAIT_TIME / $WAIT_NUM_WAITS) * 1000' | bc -l)+0.0005)/1' | bc -l"
					WAIT_AVERAGE=`echo "scale=3; ($(echo "scale=7; ($WAIT_TIME / $WAIT_NUM_WAITS) * 1000" | bc -l)+0.0005)/1" | bc -l`
				else
					WAIT_AVERAGE=""
				fi

				echodbg "Background Wait Events $WAIT_NAME: Waits=$WAIT_NUM_WAITS, Time=$WAIT_TIME, PctDBTime=$WAIT_PCT_DBTIME, Ave=$WAIT_AVERAGE"

				# Set variable based on name of wait
				eval WAIT_${WAIT_NAME}_WAITS='$WAIT_NUM_WAITS'
				eval WAIT_${WAIT_NAME}_TIME='$WAIT_TIME'
				eval WAIT_${WAIT_NAME}_AVERAGE='$WAIT_AVERAGE'
				eval WAIT_${WAIT_NAME}_PCT_DBTIME='$WAIT_PCT_DBTIME'
			fi
			continue
		fi	# End of handler routine for Background Wait Events section of AWR report

		##################################################################      Instance Activity Stats         ##################################################################
		if [ "$AWR_SECTION" = "InstanceActivityStats" ]; then
			# Routine for handling the Instance Activity Stats section of the report
			case ${AWRLINE[0]:0:32} in
				"physical read total IO requests"*)
					READ_IOPS=$(echo "${AWRLINE[0]}"| cut -c52-66|sed -e 's/^[ \t]*//;s/[ \t]*$//;s/,//g')
					echodbg "READ_IOPS = ${ENDCHAR}${READ_IOPS}${ENDCHAR}"
					;;
				"physical read total bytes"*)
					# Because this number is often very large Oracle may print it in scientific notation so we have to convert this if neccessary
					READ_THROUGHPUT=$(echo "${AWRLINE[0]}"| cut -c52-66|sed -e 's/^[ \t]*//;s/[ \t]*$//;s/,//g'| sed -e 's/E+/\*10\^/')
					# Convert to MB/sec
					if [ -n "$READ_THROUGHPUT" ]; then
						echodbg "Calling BC: READ_THROUGHPUT=echo 'scale=2; (\$(echo 'scale=6; $READ_THROUGHPUT / 1048576' | bc -l)+0.005)/1' | bc -l"
						READ_THROUGHPUT=`echo "scale=2; ($(echo "scale=6; $READ_THROUGHPUT / 1048576" | bc -l)+0.005)/1" | bc -l`
						echodbg "READ_THROUGHPUT = ${ENDCHAR}${READ_THROUGHPUT}${ENDCHAR}"
					else
						echovrb "WARNING: Unable to calculate value for READ_THROUGHPUT: $READ_THROUGHPUT"
						READ_THROUGHPUT=""
					fi
					;;
				"physical write total IO requests")
					ALL_WRITE_IOPS=$(echo "${AWRLINE[0]}"| cut -c52-66|sed -e 's/^[ \t]*//;s/[ \t]*$//;s/,//g')
					echodbg "ALL_WRITE_IOPS = ${ENDCHAR}${ALL_WRITE_IOPS}${ENDCHAR}"
					;;
				"physical write total bytes"*)
					# Because this number is often very large Oracle may print it in scientific notation so we have to convert this if neccessary
					ALL_WRITE_THROUGHPUT=$(echo "${AWRLINE[0]}"| cut -c52-66|sed -e 's/^[ \t]*//;s/[ \t]*$//;s/,//g'| sed -e 's/E+/\*10\^/')
					# Convert to MB/sec
					if [ -n "$ALL_WRITE_THROUGHPUT" ]; then
						echodbg "Calling BC: ALL_WRITE_THROUGHPUT=echo 'scale=2; (\$(echo 'scale=6; $ALL_WRITE_THROUGHPUT / 1048576' | bc -l)+0.005)/1' | bc -l"
						ALL_WRITE_THROUGHPUT=`echo "scale=2; ($(echo "scale=6; $ALL_WRITE_THROUGHPUT / 1048576" | bc -l)+0.005)/1" | bc -l`
						echodbg "ALL_WRITE_THROUGHPUT = ${ENDCHAR}${ALL_WRITE_THROUGHPUT}${ENDCHAR}"
					else
						echovrb "WARNING: Unable to calculate value for ALL_WRITE_THROUGHPUT: $ALL_WRITE_THROUGHPUT"
						ALL_WRITE_THROUGHPUT=""
					fi
					;;
				"redo writes"*)
					REDO_WRITE_IOPS=$(echo "${AWRLINE[0]}"| cut -c52-66|sed -e 's/^[ \t]*//;s/[ \t]*$//;s/,//g')
					echodbg "REDO_WRITE_IOPS = ${ENDCHAR}${REDO_WRITE_IOPS}${ENDCHAR}"
					;;
				"          ----------------------")
					# End of Instance Activity Stats section of the report
					echovrb "End of Instance Activity Stats section found at line $ROWCNT"
					echovrb "No further sections to search for - jump to post-processing"
					AWR_SECTION="EndOfReport"
					# This is the last section so break out of the while loop to begin post processing
					break
					;;
			esac
			continue
		fi

		##################################################################           Thread Activity            ##################################################################
		if [ "$AWR_SECTION" = "ThreadActivity" ]; then
			# Routine for handling the Instance Activity Stats - Thread Activity section of the report
			# Examine two words
			case ${AWRLINE[@]:0:2} in
				"log switches")
					# Read information on log switches - remove commas and any carriage return
					AWR_LOG_SWITCHES_TOTAL=$(echo ${AWRLINE[3]} |sed -e 's/,//g')
					AWR_LOG_SWITCHES_PERHOUR=$(echo ${AWRLINE[4]} |sed -e 's/,//g' | tr -d '\r')
					echodbg "AWR_LOG_SWITCHES_TOTAL = ${ENDCHAR}${AWR_LOG_SWITCHES_TOTAL}${ENDCHAR}"
					echodbg "AWR_LOG_SWITCHES_PERHOUR = ${ENDCHAR}${AWR_LOG_SWITCHES_PERHOUR}${ENDCHAR}"
					echovrb "Finished scanning file at line $ROWCNT"
					break
					;;
				*)
					# Catch all other lines and ignore
					continue
					;;
			esac
		fi

	# End of the while read loop
	done < $AWRFILE
	# Finished reading AWR report on line by line basis

	##################################################################        Post Processing Section       ##################################################################
	# Start post processing section for files of known format
	if [ "$AWR_FORMAT" != 'Unknown' ]; then
		echovrb "Start post-processing section"
		# Based on comparison of NUM_CPUS and Average Active Sessions, set BUSY flag to Y or N
		if [ -n "$DB_NUM_CPUS" ] && [ -n "$AWR_AAS" ]; then
			# Set BUSY flag if AAS higher than number of CPUs
			echodbg "Calling BC: echo '$AWR_AAS > $DB_NUM_CPUS' | bc -l"
			if [ $(echo "$AWR_AAS > $DB_NUM_CPUS" | bc -l) = 1 ]; then
				AWR_BUSY_FLAG="Y"
			else
				AWR_BUSY_FLAG="N"
			fi
		fi

		# Calculate total and data write IOPS values 
		TOTAL_IOPS=0
		DATA_WRITE_IOPS=0
		if [ -n "$READ_IOPS" ]; then
			echodbg "Calling BC: TOTAL_IOPS=echo 'scale=1; $TOTAL_IOPS + $READ_IOPS' | bc -l"
			TOTAL_IOPS=`echo "scale=1; $TOTAL_IOPS + $READ_IOPS" | bc -l`
			echodbg "TOTAL_IOPS = ${ENDCHAR}${TOTAL_IOPS}${ENDCHAR}"
		fi
		if [ -n "$ALL_WRITE_IOPS" ]; then
			echodbg "Calling BC: TOTAL_IOPS=echo 'scale=1; $TOTAL_IOPS + $ALL_WRITE_IOPS' | bc -l"
			TOTAL_IOPS=`echo "scale=1; $TOTAL_IOPS + $ALL_WRITE_IOPS" | bc -l`
			echodbg "TOTAL_IOPS = ${ENDCHAR}${TOTAL_IOPS}${ENDCHAR}"
			if [ -n "$REDO_WRITE_IOPS" ]; then
				echodbg "Calling BC: ALL_WRITE_IOPS=echo 'scale=1; $ALL_WRITE_IOPS - $REDO_WRITE_IOPS' | bc -l"
				DATA_WRITE_IOPS=`echo "scale=1; $ALL_WRITE_IOPS - $REDO_WRITE_IOPS" | bc -l`
				echodbg "DATA_WRITE_IOPS = ${ENDCHAR}${DATA_WRITE_IOPS}${ENDCHAR}"
			fi
		fi
		[[ "$TOTAL_IOPS" = "0" ]] && unset TOTAL_IOPS
		[[ "$READ_IOPS" = "0" ]] && unset READ_IOPS
		[[ "$ALL_WRITE_IOPS" = "0" ]] && unset ALL_WRITE_IOPS
		[[ "$DATA_WRITE_IOPS" = "0" ]] && unset DATA_WRITE_IOPS

		# Calculate total and data write throughput values
		TOTAL_THROUGHPUT=0
		DATA_WRITE_THROUGHPUT=0
		if [ -n "$READ_THROUGHPUT" ]; then
			echodbg "Calling BC: TOTAL_THROUGHPUT=echo 'scale=1; $TOTAL_THROUGHPUT + $READ_THROUGHPUT' | bc -l"
			TOTAL_THROUGHPUT=`echo "scale=1; $TOTAL_THROUGHPUT + $READ_THROUGHPUT" | bc -l`
			echodbg "TOTAL_THROUGHPUT = ${ENDCHAR}${TOTAL_THROUGHPUT}${ENDCHAR}"
		fi
		if [ -n "$ALL_WRITE_THROUGHPUT" ]; then
			echodbg "Calling BC: TOTAL_THROUGHPUT=echo 'scale=1; $TOTAL_THROUGHPUT + $ALL_WRITE_THROUGHPUT | bc -l"
			TOTAL_THROUGHPUT=`echo "scale=1; $TOTAL_THROUGHPUT + $ALL_WRITE_THROUGHPUT" | bc -l`
			echodbg "TOTAL_THROUGHPUT = ${ENDCHAR}${TOTAL_THROUGHPUT}${ENDCHAR}"
			if [ -n "$REDO_WRITE_THROUGHPUT" ]; then
				echodbg "Calling BC: ALL_WRITE_THROUGHPUT=echo 'scale=1; $ALL_WRITE_THROUGHPUT - $REDO_WRITE_THROUGHPUT' | bc -l"
				DATA_WRITE_THROUGHPUT=`echo "scale=1; $ALL_WRITE_THROUGHPUT - $REDO_WRITE_THROUGHPUT" | bc -l`
				echodbg "DATA_WRITE_THROUGHPUT = ${ENDCHAR}${DATA_WRITE_THROUGHPUT}${ENDCHAR}"
			fi
		fi
		[[ "$TOTAL_THROUGHPUT" = "0" ]] && unset TOTAL_THROUGHPUT
		[[ "$READ_THROUGHPUT" = "0" ]] && unset READ_THROUGHPUT
		[[ "$ALL_WRITE_THROUGHPUT" = "0" ]] && unset ALL_WRITE_THROUGHPUT
		[[ "$DATA_WRITE_THROUGHPUT" = "0" ]] && unset DATA_WRITE_THROUGHPUT

		# No %DB Time column present in 10g reports - calculate value for wait classes manually then round to one decimal place
		if [ "$AWR_FORMAT" = '10' ] && [ "$FOUND_FG_WAIT_CLASS"="$AWR_FOUND" ]; then
			echovrb "Calculating Wait Class data: note that %DBTime in 10g reports can total to >100%"
			echovrb "                           - this is a known issue and is fixed in 11g"
			# First check that we have a value for %DB Time otherwise skip the calculation section
			if [ -z "$AWR_DB_TIME" ] || [ "$AWR_DB_TIME" = 0 ]; then
				echovrb "WARNING: Unable to calculate Wait Class %DBTime values due to unknown value for DB Time: $AWR_DB_TIME"
				continue
			fi
			# See comments in header section for explanation of the way bc is used in calculating the average on the following lines
			if [ -n "$WCLASS_ADMIN_WAIT_TIME" ]; then
				echodbg "Calling BC: WCLASS_ADMIN_PCT_DBTIME=echo 'scale=1; (\$(echo 'scale=5; ($WCLASS_ADMIN_WAIT_TIME/($AWR_DB_TIME*60))*100' | bc -l)+0.05)/1' | bc -l"
				WCLASS_ADMIN_PCT_DBTIME=`echo "scale=1; ($(echo "scale=5; ($WCLASS_ADMIN_WAIT_TIME/($AWR_DB_TIME*60))*100" | bc -l)+0.05)/1" | bc -l`
				echovrb "Calculated Administrative Wait Class %DBTime as $WCLASS_ADMIN_PCT_DBTIME %"
			else
				echovrb "No values found for Administrative Wait Class"
			fi
			if [ -n "$WCLASS_APPLN_WAIT_TIME" ]; then
				echodbg "Calling BC: WCLASS_APPLN_PCT_DBTIME=echo 'scale=1; (\$(echo 'scale=5; ($WCLASS_APPLN_WAIT_TIME/($AWR_DB_TIME*60))*100' | bc -l)+0.05)/1' | bc -l"
				WCLASS_APPLN_PCT_DBTIME=`echo "scale=1; ($(echo "scale=5; ($WCLASS_APPLN_WAIT_TIME/($AWR_DB_TIME*60))*100" | bc -l)+0.05)/1" | bc -l`
				echovrb "Calculated Application Wait Class %DBTime as $WCLASS_APPLN_PCT_DBTIME %"
			else
				echovrb "No values found for Application Wait Class"
			fi
			if [ -n "$WCLASS_CLSTR_WAIT_TIME" ]; then
				echodbg "Calling BC: WCLASS_CLSTR_PCT_DBTIME=echo 'scale=1; (\$(echo 'scale=5; ($WCLASS_CLSTR_WAIT_TIME/($AWR_DB_TIME*60))*100' | bc -l)+0.05)/1' | bc -l"
				WCLASS_CLSTR_PCT_DBTIME=`echo "scale=1; ($(echo "scale=5; ($WCLASS_CLSTR_WAIT_TIME/($AWR_DB_TIME*60))*100" | bc -l)+0.05)/1" | bc -l`
				echovrb "Calculated Cluster Wait Class %DBTime as $WCLASS_CLSTR_PCT_DBTIME %"
			else
				echovrb "No values found for Cluster Wait Class"
			fi
			if [ -n "$WCLASS_COMMT_WAIT_TIME" ]; then
				echodbg "Calling BC: WCLASS_COMMT_PCT_DBTIME=echo 'scale=1; (\$(echo 'scale=5; ($WCLASS_COMMT_WAIT_TIME/($AWR_DB_TIME*60))*100' | bc -l)+0.05)/1' | bc -l"
				WCLASS_COMMT_PCT_DBTIME=`echo "scale=1; ($(echo "scale=5; ($WCLASS_COMMT_WAIT_TIME/($AWR_DB_TIME*60))*100" | bc -l)+0.05)/1" | bc -l`
				echovrb "Calculated Commit Wait Class %DBTime as $WCLASS_COMMT_PCT_DBTIME %"
			else
				echovrb "No values found for Commit Wait Class"
			fi
			if [ -n "$WCLASS_CNCUR_WAIT_TIME" ]; then
				echodbg "Calling BC: WCLASS_CNCUR_PCT_DBTIME=echo 'scale=1; (\$(echo 'scale=5; ($WCLASS_CNCUR_WAIT_TIME/($AWR_DB_TIME*60))*100' | bc -l)+0.05)/1' | bc -l"
				WCLASS_CNCUR_PCT_DBTIME=`echo "scale=1; ($(echo "scale=5; ($WCLASS_CNCUR_WAIT_TIME/($AWR_DB_TIME*60))*100" | bc -l)+0.05)/1" | bc -l`
				echovrb "Calculated Concurrency Wait Class %DBTime as $WCLASS_CNCUR_PCT_DBTIME %"
			else
				echovrb "No values found for Concurrency Wait Class"
			fi
			if [ -n "$WCLASS_CONFG_WAIT_TIME" ]; then
				echodbg "Calling BC: WCLASS_CONFG_PCT_DBTIME=echo 'scale=1; (\$(echo 'scale=5; ($WCLASS_CONFG_WAIT_TIME/($AWR_DB_TIME*60))*100' | bc -l)+0.05)/1' | bc -l"
				WCLASS_CONFG_PCT_DBTIME=`echo "scale=1; ($(echo "scale=5; ($WCLASS_CONFG_WAIT_TIME/($AWR_DB_TIME*60))*100" | bc -l)+0.05)/1" | bc -l`
				echovrb "Calculated Configuration Wait Class %DBTime as $WCLASS_CONFG_PCT_DBTIME %"
			else
				echovrb "No values found for Configuration Wait Class"
			fi
			if [ -n "$WCLASS_NETWK_WAIT_TIME" ]; then
				echodbg "Calling BC: WCLASS_NETWK_PCT_DBTIME=echo 'scale=1; (\$(echo 'scale=5; ($WCLASS_NETWK_WAIT_TIME/($AWR_DB_TIME*60))*100' | bc -l)+0.05)/1' | bc -l"
				WCLASS_NETWK_PCT_DBTIME=`echo "scale=1; ($(echo "scale=5; ($WCLASS_NETWK_WAIT_TIME/($AWR_DB_TIME*60))*100" | bc -l)+0.05)/1" | bc -l`
				echovrb "Calculated Network Wait Class %DBTime as $WCLASS_NETWK_PCT_DBTIME %"
			else
				echovrb "No values found for Network Wait Class"
			fi
			if [ -n "$WCLASS_OTHER_WAIT_TIME" ]; then
				echodbg "Calling BC: WCLASS_OTHER_PCT_DBTIME=echo 'scale=1; (\$(echo 'scale=5; ($WCLASS_OTHER_WAIT_TIME/($AWR_DB_TIME*60))*100' | bc -l)+0.05)/1' | bc -l"
				WCLASS_OTHER_PCT_DBTIME=`echo "scale=1; ($(echo "scale=5; ($WCLASS_OTHER_WAIT_TIME/($AWR_DB_TIME*60))*100" | bc -l)+0.05)/1" | bc -l`
				echovrb "Calculated Other Wait Class %DBTime as $WCLASS_OTHER_PCT_DBTIME %"
			else
				echovrb "No values found for Other Wait Class"
			fi
			if [ -n "$WCLASS_SCHED_WAIT_TIME" ]; then
				echodbg "Calling BC: WCLASS_SCHED_PCT_DBTIME=echo 'scale=1; (\$(echo 'scale=5; ($WCLASS_SCHED_WAIT_TIME/($AWR_DB_TIME*60))*100' | bc -l)+0.05)/1' | bc -l"
				WCLASS_SCHED_PCT_DBTIME=`echo "scale=1; ($(echo "scale=5; ($WCLASS_SCHED_WAIT_TIME/($AWR_DB_TIME*60))*100" | bc -l)+0.05)/1" | bc -l`
				echovrb "Calculated Scheduler Wait Class %DBTime as $WCLASS_SCHED_PCT_DBTIME %"
			else
				echovrb "No values found for Scheduler Wait Class"
			fi
			if [ -n "$WCLASS_USRIO_WAIT_TIME" ]; then
				echodbg "Calling BC: WCLASS_USRIO_PCT_DBTIME=echo 'scale=1; (\$(echo 'scale=5; ($WCLASS_USRIO_WAIT_TIME/($AWR_DB_TIME*60))*100' | bc -l)+0.05)/1' | bc -l"
				WCLASS_USRIO_PCT_DBTIME=`echo "scale=1; ($(echo "scale=5; ($WCLASS_USRIO_WAIT_TIME/($AWR_DB_TIME*60))*100" | bc -l)+0.05)/1" | bc -l`
				echovrb "Calculated User I/O %DBTime as $WCLASS_USRIO_PCT_DBTIME %"
			else
				echovrb "No values found for User I/O Wait Class"
			fi
			if [ -n "$WCLASS_SYSIO_WAIT_TIME" ]; then
				echodbg "Calling BC: WCLASS_SYSIO_PCT_DBTIME=echo 'scale=1; (\$(echo 'scale=5; ($WCLASS_SYSIO_WAIT_TIME/($AWR_DB_TIME*60))*100' | bc -l)+0.05)/1' | bc -l"
				WCLASS_SYSIO_PCT_DBTIME=`echo "scale=1; ($(echo "scale=5; ($WCLASS_SYSIO_WAIT_TIME/($AWR_DB_TIME*60))*100" | bc -l)+0.05)/1" | bc -l`
				echovrb "Calculated System I/O %DBTime as $WCLASS_SYSIO_PCT_DBTIME %"
			else
				echovrb "No values found for System I/O Wait Class"
			fi
		fi

		# Print warnings if certain sections were not found
		[[ "$FOUND_SYS_DETAILS" != "$AWR_FOUND" ]] && echoinf "Unable to find database system details"
		if [ "$AWR_FORMAT" -ne "10" ]; then
			[[ "$FOUND_HOST_DETAILS" != "$AWR_FOUND" ]] && echoinf "Unable to find host system details"
			[[ -z "$AWR_AAS" ]] && echoinf "Unable to calculate Average Active Sessions"
			[[ -z "$AWR_BUSY_FLAG" ]] && echoinf "Unable to determine value for BUSY flag"
		fi

		# Raise error if any critical values are null
		if [ -z "$PROFILE_DBNAME" ]; then
			echoerr "Post-process complete: unable to determine Database name"
		elif [ -z "$READ_IOPS" ]; then
			echoerr "Post-process complete: unable to determine read IOPS values"
		elif [ -z "$ALL_WRITE_IOPS" ]; then
			echoerr "Post-process complete: unable to determine write IOPS values"
		elif [ -z "$READ_THROUGHPUT" ]; then
			echoerr "Post-process complete: unable to determine read throughput values"
		elif [ -z "$ALL_WRITE_THROUGHPUT" ]; then
			echoerr "Post-process complete: unable to determine write throughput values"
		else
			echovrb "Post-processing complete"
		fi
	fi
}

# Function for printing the header row in the CSV file i.e. the descriptions of each column
print_header_row() {
	# Write header row for CSV file
	echocsv "Filename,Database Name,Instance Number,Instance Name,Database Version,Cluster,Hostname,Host OS,Num CPUs,Server Memory (GB),DB Block Size,Begin Snap,Begin Time,End Snap,End Time,Elapsed Time (mins),DB Time (mins),Average Active Sessions,Busy Flag,Logical Reads/sec,Block Changes/sec,Read IOPS,Write IOPS,Redo IOPS,All Write IOPS,Total IOPS,Read Throughput (MiB/sec),Write Throughput (MiB/sec),Redo Throughput (MiB/sec),All Write Throughput (MiB/sec),Total Throughput (MiB/sec),DB CPU Time (s),DB CPU %DBTime,Wait Class User I/O Waits,Wait Class User I/O Time (s),Wait Class User I/O Latency (ms),Wait Class User I/O %DBTime,User Calls/sec,Parses/sec,Hard Parses/sec,Logons/sec,Executes/sec,Transactions/sec,Buffer Hit Ratio (%),In-Memory Sort Ratio (%),Log Switches (Total),Log Switches (Per Hour),Top5 Event1 Name,Top5 Event1 Class,Top5 Event1 Waits,Top5 Event1 Time (s),Top5 Event1 Average Time (ms),Top5 Event1 %DBTime,Top5 Event2 Name,Top5 Event2 Class,Top5 Event2 Waits,Top5 Event2 Time (s),Top5 Event2 Average Time (ms),Top5 Event2 %DBTime,Top5 Event3 Name,Top5 Event3 Class,Top5 Event3 Waits,Top5 Event3 Time (s),Top5 Event3 Average Time (ms),Top5 Event3 %DBTime,Top5 Event4 Name,Top5 Event4 Class,Top5 Event4 Waits,Top5 Event4 Time (s),Top5 Event4 Average Time (ms),Top5 Event4 %DBTime,Top5 Event5 Name,Top5 Event5 Class,Top5 Event5 Waits,Top5 Event5 Time (s),Top5 Event5 Average Time (ms),Top5 Event5 %DBTime,db file sequential read Waits,db file sequential read Time (s),db file sequential read Latency (ms),db file sequential read %DBTime,db file scattered read Waits,db file scattered read Time (s),db file scattered read Latency (ms),db file scattered read %DBTime,direct path read Waits,direct path read Time (s),direct path read Latency (ms),direct path read %DBTime,direct path write Waits,direct path write Time (s),direct path write Latency (ms),direct path write %DBTime,direct path read temp Waits,direct path read temp Time (s),direct path read temp Latency (ms),direct path read temp %DBTime,direct path write temp Waits,direct path write temp Time (s),direct path write temp Latency (ms),direct path write temp %DBTime,log file sync Waits,log file sync Time (s),log file sync Latency (ms),log file sync %DBTime,db file parallel write Waits,db file parallel write Time (s),db file parallel write Latency (ms),db file parallel write %DBTime,log file parallel write Waits,log file parallel write Time (s),log file parallel write Latency (ms),log file parallel write %DBTime,log file sequential read Waits,log file sequential read Time (s),log file sequential read Latency (ms),log file sequential read %DBTime,OS busy time,OS idle time,OS iowait time,OS sys time,OS user time,OS cpu wait time,OS resource mgr wait time,Data Guard Flag,Exadata Flag,Wait Class Admin Waits,Wait Class Admin Time (s),Wait Class Admin Latency (ms),Wait Class Admin %DBTime,Wait Class Application Waits,Wait Class Application Time (s),Wait Class Application Latency (ms),Wait Class Application %DBTime,Wait Class Cluster Waits,Wait Class Cluster Time (s),Wait Class Cluster Latency (ms),Wait Class Cluster %DBTime,Wait Class Commit Waits,Wait Class Commit Time (s),Wait Class Commit Latency (ms),Wait Class Commit %DBTime,Wait Class Concurrency Waits,Wait Class Concurrency Time (s),Wait Class Concurrency Latency (ms),Wait Class Concurrency %DBTime,Wait Class Configuration Waits,Wait Class Configuration Time (s),Wait Class Configuration Latency (ms),Wait Class Configuration %DBTime,Wait Class Network Waits,Wait Class Network Time (s),Wait Class Network Latency (ms),Wait Class Network %DBTime,Wait Class Other Waits,Wait Class Other Time (s),Wait Class Other Latency (ms),Wait Class Other %DBTime,Wait Class System I/O Waits,Wait Class System I/O Time (s),Wait Class System I/O Latency (ms),Wait Class System I/O %DBTime"
}

# Function for printing extracted AWR information when in verbose mode
print_report_info() {
	# Print harvested information to errinf function
	echoprt "                           Filename = $AWRFILENAME"
	echoprt "                         AWR Format = $AWR_FORMAT"
	echoprt "                      Database Name = $PROFILE_DBNAME"
	echoprt "                    Instance Number = $PROFILE_INSTANCENUM"
	echoprt "                      Instance Name = $PROFILE_INSTANCENAME"
	echoprt "                   Database Version = $PROFILE_DBVERSION"
	echoprt "                        Cluster Y/N = $PROFILE_CLUSTER"
	echoprt "                           Hostname = $DB_HOSTNAME"
	echoprt "                            Host OS = $DB_HOST_OS"
	echoprt "                     Number of CPUs = $DB_NUM_CPUS"
	echoprt "                      Server Memory = $DB_HOST_MEM"
	echoprt "                       DB Blocksize = $DB_BLOCK_SIZE"
	echoprt "                         Begin Snap = $AWR_BEGIN_SNAP"
	echoprt "                         Begin Time = $AWR_BEGIN_TIME"
	echoprt "                           End Snap = $AWR_END_SNAP"
	echoprt "                           End Time = $AWR_END_TIME"
	echoprt "                       Elapsed Time = $AWR_ELAPSED_TIME"
	echoprt "                            DB Time = $AWR_DB_TIME"
	echoprt "                                AAS = $AWR_AAS"
	echoprt "                              Busy? = $AWR_BUSY_FLAG"
	echoprt "                  Logical Reads/sec = $AWR_LOGICAL_READS"
	echoprt "                  Block Changes/sec = $AWR_BLOCK_CHANGES"
	echoprt "                          Read IOPS = $READ_IOPS"
	echoprt "                    Data Write IOPS = $DATA_WRITE_IOPS"
	echoprt "                    Redo Write IOPS = $REDO_WRITE_IOPS"
	echoprt "                   Total Write IOPS = $ALL_WRITE_IOPS"
	echoprt "                         Total IOPS = $TOTAL_IOPS"
	echoprt "          Read Throughput (MiB/sec) = $READ_THROUGHPUT"
	echoprt "    Data Write Throughput (MiB/sec) = $DATA_WRITE_THROUGHPUT"
	echoprt "    Redo Write Throughput (MiB/sec) = $REDO_WRITE_THROUGHPUT"
	echoprt "   Total Write Throughput (MiB/sec) = $ALL_WRITE_THROUGHPUT"
	echoprt "         Total Throughput (MiB/sec) = $TOTAL_THROUGHPUT"
	echoprt "                     DB CPU Time ms = $AWR_DB_CPU"
	echoprt "                     DB CPU %DBTime = $AWR_DB_CPU_PCT_DBTIME"
	echoprt "      Wait Class User IO  Num Waits = $WCLASS_USRIO_NUM_WAITS"
	echoprt "      Wait Class User IO  Wait Time = $WCLASS_USRIO_WAIT_TIME"
	echoprt "      Wait Class User IO Latency ms = $WCLASS_USRIO_AVEWAIT"
	echoprt "      Wait Class User IO    %DBTime = $WCLASS_USRIO_PCT_DBTIME"
	echoprt "                     User Calls/sec = $AWR_USER_CALLS"
	echoprt "                         Parses/sec = $AWR_PARSES"
	echoprt "                    Hard Parses/sec = $AWR_HARD_PARSES"
	echoprt "                         Logons/sec = $AWR_LOGONS"
	echoprt "                       Executes/sec = $AWR_EXECUTES"
	echoprt "                   Transactions/sec = $AWR_TRANSACTIONS"
	echoprt "                   Buffer Hit Ratio = $BUFFER_HIT_RATIO"
	echoprt "               In-Memory Sort Ratio = $INMEMORY_SORT_RATIO"
	echoprt "              Log Switches    Total = $AWR_LOG_SWITCHES_TOTAL"
	echoprt "              Log Switches Per Hour = $AWR_LOG_SWITCHES_PERHOUR"
	echoprt "         Top 5 Timed Event1    Name = $TOP5EVENT1_NAME"
	echoprt "         Top 5 Timed Event1   Class = $TOP5EVENT1_CLASS"
	echoprt "         Top 5 Timed Event1   Waits = $TOP5EVENT1_WAITS"
	echoprt "         Top 5 Timed Event1 Time ms = $TOP5EVENT1_TIME"
	echoprt "         Top 5 Timed Event1 Average = $TOP5EVENT1_AVERAGE"
	echoprt "         Top 5 Timed Event1 %DBTime = $TOP5EVENT1_PCT_DBTIME"
	echoprt "         Top 5 Timed Event2    Name = $TOP5EVENT2_NAME"
	echoprt "         Top 5 Timed Event2   Class = $TOP5EVENT2_CLASS"
	echoprt "         Top 5 Timed Event2   Waits = $TOP5EVENT2_WAITS"
	echoprt "         Top 5 Timed Event2 Time ms = $TOP5EVENT2_TIME"
	echoprt "         Top 5 Timed Event2 Average = $TOP5EVENT2_AVERAGE"
	echoprt "         Top 5 Timed Event2 %DBTime = $TOP5EVENT2_PCT_DBTIME"
	echoprt "         Top 5 Timed Event3    Name = $TOP5EVENT3_NAME"
	echoprt "         Top 5 Timed Event3   Class = $TOP5EVENT3_CLASS"
	echoprt "         Top 5 Timed Event3   Waits = $TOP5EVENT3_WAITS"
	echoprt "         Top 5 Timed Event3 Time ms = $TOP5EVENT3_TIME"
	echoprt "         Top 5 Timed Event3 Average = $TOP5EVENT3_AVERAGE"
	echoprt "         Top 5 Timed Event3 %DBTime = $TOP5EVENT3_PCT_DBTIME"
	echoprt "         Top 5 Timed Event4    Name = $TOP5EVENT4_NAME"
	echoprt "         Top 5 Timed Event4   Class = $TOP5EVENT4_CLASS"
	echoprt "         Top 5 Timed Event4   Waits = $TOP5EVENT4_WAITS"
	echoprt "         Top 5 Timed Event4 Time ms = $TOP5EVENT4_TIME"
	echoprt "         Top 5 Timed Event4 Average = $TOP5EVENT4_AVERAGE"
	echoprt "         Top 5 Timed Event4 %DBTime = $TOP5EVENT4_PCT_DBTIME"
	echoprt "         Top 5 Timed Event5    Name = $TOP5EVENT5_NAME"
	echoprt "         Top 5 Timed Event5   Class = $TOP5EVENT5_CLASS"
	echoprt "         Top 5 Timed Event5   Waits = $TOP5EVENT5_WAITS"
	echoprt "         Top 5 Timed Event5 Time ms = $TOP5EVENT5_TIME"
	echoprt "         Top 5 Timed Event5 Average = $TOP5EVENT5_AVERAGE"
	echoprt "         Top 5 Timed Event5 %DBTime = $TOP5EVENT5_PCT_DBTIME"
	echoprt "FG db file sequential read    Waits = $WAIT_DFSR_WAITS"
	echoprt "FG db file sequential read  Time ms = $WAIT_DFSR_TIME"
	echoprt "FG db file sequential read  Average = $WAIT_DFSR_AVERAGE"
	echoprt "FG db file sequential read  %DBTime = $WAIT_DFSR_PCT_DBTIME"
	echoprt "FG db file scattered read     Waits = $WAIT_DFXR_WAITS"
	echoprt "FG db file scattered read   Time ms = $WAIT_DFXR_TIME"
	echoprt "FG db file scattered read   Average = $WAIT_DFXR_AVERAGE"
	echoprt "FG db file scattered read   %DBTime = $WAIT_DFXR_PCT_DBTIME"
	echoprt "FG direct path read           Waits = $WAIT_DPRD_WAITS"
	echoprt "FG direct path read         Time ms = $WAIT_DPRD_TIME"
	echoprt "FG direct path read         Average = $WAIT_DPRD_AVERAGE"
	echoprt "FG direct path read         %DBTime = $WAIT_DPRD_PCT_DBTIME"
	echoprt "FG direct path write          Waits = $WAIT_DPWR_WAITS"
	echoprt "FG direct path write        Time ms = $WAIT_DPWR_TIME"
	echoprt "FG direct path write        Average = $WAIT_DPWR_AVERAGE"
	echoprt "FG direct path write        %DBTime = $WAIT_DPWR_PCT_DBTIME"
	echoprt "FG direct path read temp      Waits = $WAIT_DPRT_WAITS"
	echoprt "FG direct path read temp    Time ms = $WAIT_DPRT_TIME"
	echoprt "FG direct path read temp    Average = $WAIT_DPRT_AVERAGE"
	echoprt "FG direct path read temp    %DBTime = $WAIT_DPRT_PCT_DBTIME"
	echoprt "FG direct path write temp     Waits = $WAIT_DPWT_WAITS"
	echoprt "FG direct path write temp   Time ms = $WAIT_DPWT_TIME"
	echoprt "FG direct path write temp   Average = $WAIT_DPWT_AVERAGE"
	echoprt "FG direct path write temp   %DBTime = $WAIT_DPWT_PCT_DBTIME"
	echoprt "FG log file sync              Waits = $WAIT_LFSY_WAITS"
	echoprt "FG log file sync            Time ms = $WAIT_LFSY_TIME"
	echoprt "FG log file sync            Average = $WAIT_LFSY_AVERAGE"
	echoprt "FG log file sync            %DBTime = $WAIT_LFSY_PCT_DBTIME"
	echoprt "BG db file parallel write     Waits = $WAIT_DFPW_WAITS"
	echoprt "BG db file parallel write   Time ms = $WAIT_DFPW_TIME"
	echoprt "BG db file parallel write   Average = $WAIT_DFPW_AVERAGE"
	echoprt "BG db file parallel write   %BGTime = $WAIT_DFPW_PCT_DBTIME"
	echoprt "BG log file parallel write    Waits = $WAIT_LFPW_WAITS"
	echoprt "BG log file parallel write  Time ms = $WAIT_LFPW_TIME"
	echoprt "BG log file parallel write  Average = $WAIT_LFPW_AVERAGE"
	echoprt "BG log file parallel write  %BGTime = $WAIT_LFPW_PCT_DBTIME"
	echoprt "BG log file sequential read   Waits = $WAIT_LFSR_WAITS"
	echoprt "BG log file sequential read Time ms = $WAIT_LFSR_TIME"
	echoprt "BG log file sequential read Average = $WAIT_LFSR_AVERAGE"
	echoprt "BG log file sequential read %BGTime = $WAIT_LFSR_PCT_DBTIME"
	echoprt "OS busy time              (sec/100) = $OS_BUSY_TIME"
	echoprt "OS idle time              (sec/100) = $OS_IDLE_TIME"
	echoprt "OS iowait time            (sec/100) = $OS_IOWAIT_TIME"
	echoprt "OS sys time               (sec/100) = $OS_SYS_TIME"
	echoprt "OS user time              (sec/100) = $OS_USER_TIME"
	echoprt "OS cpu wait time          (sec/100) = $OS_CPU_WAIT_TIME"
	echoprt "OS resource mgr wait time (sec/100) = $OS_RSRC_MGR_WAIT_TIME"
	echoprt "                 Data Guard in use? = $DATA_GUARD_FLAG"
	echoprt "                    Exadata in use? = $EXADATA_FLAG"
	echoprt "        Wait Class Admin  Num Waits = $WCLASS_ADMIN_NUM_WAITS"
	echoprt "        Wait Class Admin  Wait Time = $WCLASS_ADMIN_WAIT_TIME"
	echoprt "        Wait Class Admin Latency ms = $WCLASS_ADMIN_AVEWAIT"
	echoprt "        Wait Class Admin    %DBTime = $WCLASS_ADMIN_PCT_DBTIME"
	echoprt "  Wait Class Application  Num Waits = $WCLASS_APPLN_NUM_WAITS"
	echoprt "  Wait Class Application  Wait Time = $WCLASS_APPLN_WAIT_TIME"
	echoprt "  Wait Class Application Latency ms = $WCLASS_APPLN_AVEWAIT"
	echoprt "  Wait Class Application    %DBTime = $WCLASS_APPLN_PCT_DBTIME"
	echoprt "      Wait Class Cluster  Num Waits = $WCLASS_CLSTR_NUM_WAITS"
	echoprt "      Wait Class Cluster  Wait Time = $WCLASS_CLSTR_WAIT_TIME"
	echoprt "      Wait Class Cluster Latency ms = $WCLASS_CLSTR_AVEWAIT"
	echoprt "      Wait Class Cluster    %DBTime = $WCLASS_CLSTR_PCT_DBTIME"
	echoprt "       Wait Class Commit  Num Waits = $WCLASS_COMMT_NUM_WAITS"
	echoprt "       Wait Class Commit  Wait Time = $WCLASS_COMMT_WAIT_TIME"
	echoprt "       Wait Class Commit Latency ms = $WCLASS_COMMT_AVEWAIT"
	echoprt "       Wait Class Commit    %DBTime = $WCLASS_COMMT_PCT_DBTIME"
	echoprt "  Wait Class Concurrency  Num Waits = $WCLASS_CNCUR_NUM_WAITS"
	echoprt "  Wait Class Concurrency  Wait Time = $WCLASS_CNCUR_WAIT_TIME"
	echoprt "  Wait Class Concurrency Latency ms = $WCLASS_CNCUR_AVEWAIT"
	echoprt "  Wait Class Concurrency    %DBTime = $WCLASS_CNCUR_PCT_DBTIME"
	echoprt "Wait Class Configuration  Num Waits = $WCLASS_CONFG_NUM_WAITS"
	echoprt "Wait Class Configuration  Wait Time = $WCLASS_CONFG_WAIT_TIME"
	echoprt "Wait Class Configuration Latency ms = $WCLASS_CONFG_AVEWAIT"
	echoprt "Wait Class Configuration    %DBTime = $WCLASS_CONFG_PCT_DBTIME"
	echoprt "      Wait Class Network  Num Waits = $WCLASS_NETWK_NUM_WAITS"
	echoprt "      Wait Class Network  Wait Time = $WCLASS_NETWK_WAIT_TIME"
	echoprt "      Wait Class Network Latency ms = $WCLASS_NETWK_AVEWAIT"
	echoprt "      Wait Class Network    %DBTime = $WCLASS_NETWK_PCT_DBTIME"
	echoprt "        Wait Class Other  Num Waits = $WCLASS_OTHER_NUM_WAITS"
	echoprt "        Wait Class Other  Wait Time = $WCLASS_OTHER_WAIT_TIME"
	echoprt "        Wait Class Other Latency ms = $WCLASS_OTHER_AVEWAIT"
	echoprt "        Wait Class Other    %DBTime = $WCLASS_OTHER_PCT_DBTIME"
	echoprt "    Wait Class System IO  Num Waits = $WCLASS_SYSIO_NUM_WAITS"
	echoprt "    Wait Class System IO  Wait Time = $WCLASS_SYSIO_WAIT_TIME"
	echoprt "    Wait Class System IO Latency ms = $WCLASS_SYSIO_AVEWAIT"
	echoprt "    Wait Class System IO    %DBTime = $WCLASS_SYSIO_PCT_DBTIME"
}

# Start of main program - check that parameters have been passed in
echo "" 1>&2
[[ "$#" -eq 0 ]] && usage

# Process calling parameters
while getopts ":hHnpsvX" opt; do
	case $opt in
		h)
			# Print usage information and then exit
			usage
			;;
		H)
			# Print the header row and then exit
			[[ "$HEADERROW" = 0 ]] && usage "Header and NoHeader are conflicting options"
			HEADERROW=2
			;;
		n)
			# Do not print the header row in the CSV file
			[[ "$HEADERROW" = 2 ]] && usage "Header and NoHeader are conflicting options"
			HEADERROW=0
			;;
		p)
			[[ "$SILENT" = 1 ]] && usage "Silent and Print Report Info are conflicting options"
			PRINT_REPORT_INFO=1
			;;
		s)
			[[ "$VERBOSE" = 1 ]] && usage "Silent and Verbose are conflicting options"
			[[ "$PRINT_REPORT_INFO" = 1 ]] && usage "Silent and Print Report Info are conflicting options"
			SILENT=1
			;;
		v)
			[[ "$SILENT" = 1 ]] && usage "Silent and Verbose are conflicting options"
			VERBOSE=1
			PRINT_REPORT_INFO=1
			echovrb "Running in verbose mode"
			;;
		X)
			DEBUG=1
			echodbg "Running in debug mode - expect lots of output..."
			;;
		\?)
			usage "Invalid option -$OPTARG"
			;;
	esac
done

# If debug mode enabled, automatically enable verbose mode and disable silent mode
if [ "$DEBUG" = 1 ]; then
	VERBOSE=1
	SILENT=0
	# Add an field terminator for use with debugging the contents of variables 
	ENDCHAR="|"
	echodbg "Script called with parameters: $*"
fi

# Determine if we are just printing the header row and then exiting
if [ "$HEADERROW" = 2 ]; then
	echoinf "Printing header row and then exiting (found -H flag)"
	print_header_row
	exit $EXIT_SUCCESS
fi

# Check that basic calculator is installed, otherwise exit with error
command -v bc >/dev/null 2>&1
if [ "$?" = 0 ]; then
	echodbg "Found basic calculator installed in path $PATH"
else
	echovrb "Basic Calculator not found in path $PATH"
	echoerr "Basic Calculator (bc) not found - see Appendix in Manual if using Cygwin"
	exit $EXIT_FAILURE
fi

# Set Internal Field Seperator to be word delimited
set_ifs_to_word_delimited

# Once switches have been processed, check filenames have been passed in too
shift $(($OPTIND - 1))
[[ "$#" -eq 0 ]] && usage "Filename(s) required"

# Determine if we should print the header row as the first line of the CSV file
if [ "$HEADERROW" = 1 ]; then
	echovrb "Printing header row"
	print_header_row
else
	echoinf "Printing of header row disabled with -n flag"
fi

# Main loop - Iterate through all files
while (( "$#" )); do
	let FILECNT++
	# Check file is readable
	if [ -r "$1" ]; then
		AWRFILE=$1
		echovrb " "
		echoinf "Analyzing file $AWRFILE at `date +'%F %T'`"
		# Perform checks to ensure file is an AWR report but not in HTML format
		CHECK_HTML=$(sed -n -e '1,5 p' $AWRFILE | grep -i "<HTML>" | wc -l)
		CHECK_STATSPACK=$(sed -n -e '1,5 p' $AWRFILE | grep STATSPACK | wc -l)
		CHECK_AWR=$(sed -n -e '1,5 p' $AWRFILE | grep "WORKLOAD REPOSITORY" | wc -l)
		if [ "$CHECK_HTML" -gt "0" ]; then
			# File was in HTML format
			echoerr "$1 is in HTML format - ignoring..."
		elif [ "$CHECK_STATSPACK" -gt "0" ]; then
			# File was STATSPACK and not AWR Report
			echoerr "$1 is a STATSPACK file - ignoring..."
		elif [ "$CHECK_AWR" -gt "0" ]; then
			# Reset global variables
			unset PROFILE_DBNAME PROFILE_INSTANCENUM PROFILE_INSTANCENAME PROFILE_DBVERSION PROFILE_CLUSTER DB_HOSTNAME DB_HOST_OS DB_NUM_CPUS DB_HOST_MEM DB_BLOCK_SIZE AWR_BEGIN_SNAP AWR_BEGIN_TIME AWR_END_SNAP AWR_END_TIME AWR_ELAPSED_TIME AWR_ELAPSED_TIME_SECS AWR_DB_TIME AWR_AAS AWR_BUSY_FLAG AWR_LOGICAL_READS AWR_BLOCK_CHANGES READ_IOPS DATA_WRITE_IOPS REDO_WRITE_IOPS ALL_WRITE_IOPS TOTAL_IOPS READ_THROUGHPUT DATA_WRITE_THROUGHPUT REDO_WRITE_THROUGHPUT ALL_WRITE_THROUGHPUT TOTAL_THROUGHPUT AWR_DB_CPU AWR_DB_CPU_PCT_DBTIME WCLASS_USRIO_NUM_WAITS WCLASS_USRIO_WAIT_TIME WCLASS_USRIO_AVEWAIT WCLASS_USRIO_PCT_DBTIME AWR_USER_CALLS AWR_PARSES AWR_HARD_PARSES AWR_LOGONS AWR_EXECUTES AWR_TRANSACTIONS BUFFER_HIT_RATIO INMEMORY_SORT_RATIO AWR_LOG_SWITCHES_TOTAL AWR_LOG_SWITCHES_PERHOUR
			unset TOP5EVENT1_NAME TOP5EVENT1_CLASS TOP5EVENT1_WAITS TOP5EVENT1_TIME TOP5EVENT1_AVERAGE TOP5EVENT1_PCT_DBTIME TOP5EVENT2_NAME TOP5EVENT2_CLASS TOP5EVENT2_WAITS TOP5EVENT2_TIME TOP5EVENT2_AVERAGE TOP5EVENT2_PCT_DBTIME TOP5EVENT3_NAME TOP5EVENT3_CLASS TOP5EVENT3_WAITS TOP5EVENT3_TIME TOP5EVENT3_AVERAGE TOP5EVENT3_PCT_DBTIME TOP5EVENT4_NAME TOP5EVENT4_CLASS TOP5EVENT4_WAITS TOP5EVENT4_TIME TOP5EVENT4_AVERAGE TOP5EVENT4_PCT_DBTIME TOP5EVENT5_NAME TOP5EVENT5_CLASS TOP5EVENT5_WAITS TOP5EVENT5_TIME TOP5EVENT5_AVERAGE TOP5EVENT5_PCT_DBTIME
			unset WAIT_DFSR_WAITS WAIT_DFSR_TIME WAIT_DFSR_AVERAGE WAIT_DFSR_PCT_DBTIME WAIT_DFXR_WAITS WAIT_DFXR_TIME WAIT_DFXR_AVERAGE WAIT_DFXR_PCT_DBTIME WAIT_DPRD_WAITS WAIT_DPRD_TIME WAIT_DPRD_AVERAGE WAIT_DPRD_PCT_DBTIME WAIT_DPWR_WAITS WAIT_DPWR_TIME WAIT_DPWR_AVERAGE WAIT_DPWR_PCT_DBTIME WAIT_DPRT_WAITS WAIT_DPRT_TIME WAIT_DPRT_AVERAGE WAIT_DPRT_PCT_DBTIME WAIT_DPWT_WAITS WAIT_DPWT_TIME WAIT_DPWT_AVERAGE WAIT_DPWT_PCT_DBTIME WAIT_LFSY_WAITS WAIT_LFSY_TIME WAIT_LFSY_AVERAGE WAIT_LFSY_PCT_DBTIME WAIT_DFPW_WAITS WAIT_DFPW_TIME WAIT_DFPW_AVERAGE WAIT_DFPW_PCT_DBTIME WAIT_LFPW_WAITS WAIT_LFPW_TIME WAIT_LFPW_AVERAGE WAIT_LFPW_PCT_DBTIME WAIT_LFSR_WAITS WAIT_LFSR_TIME WAIT_LFSR_AVERAGE WAIT_LFSR_PCT_DBTIME
			unset OS_BUSY_TIME OS_IDLE_TIME OS_IOWAIT_TIME OS_SYS_TIME OS_USER_TIME OS_CPU_WAIT_TIME OS_RSRC_MGR_WAIT_TIME DATA_GUARD_FLAG EXADATA_FLAG WCLASS_ADMIN_NUM_WAITS WCLASS_ADMIN_WAIT_TIME WCLASS_ADMIN_AVEWAIT WCLASS_ADMIN_PCT_DBTIME WCLASS_APPLN_NUM_WAITS WCLASS_APPLN_WAIT_TIME WCLASS_APPLN_AVEWAIT WCLASS_APPLN_PCT_DBTIME WCLASS_CLSTR_NUM_WAITS WCLASS_CLSTR_WAIT_TIME WCLASS_CLSTR_AVEWAIT WCLASS_CLSTR_PCT_DBTIME WCLASS_COMMT_NUM_WAITS WCLASS_COMMT_WAIT_TIME WCLASS_COMMT_AVEWAIT WCLASS_COMMT_PCT_DBTIME WCLASS_CNCUR_NUM_WAITS WCLASS_CNCUR_WAIT_TIME WCLASS_CNCUR_AVEWAIT WCLASS_CNCUR_PCT_DBTIME WCLASS_CONFG_NUM_WAITS WCLASS_CONFG_WAIT_TIME WCLASS_CONFG_AVEWAIT WCLASS_CONFG_PCT_DBTIME WCLASS_NETWK_NUM_WAITS WCLASS_NETWK_WAIT_TIME WCLASS_NETWK_AVEWAIT WCLASS_NETWK_PCT_DBTIME WCLASS_OTHER_NUM_WAITS WCLASS_OTHER_WAIT_TIME WCLASS_OTHER_AVEWAIT WCLASS_OTHER_PCT_DBTIME WCLASS_SYSIO_NUM_WAITS WCLASS_SYSIO_WAIT_TIME WCLASS_SYSIO_AVEWAIT WCLASS_SYSIO_PCT_DBTIME
			# Set Data Guard and Exadata flags to N
			DATA_GUARD_FLAG="N"
			EXADATA_FLAG="N"
			# Strip any path from filename
			AWRFILENAME=`basename $AWRFILE`
			# Harvest data from report
			process_awr_report
			# Print harvested information to errinf function
			[[ "$PRINT_REPORT_INFO" = 1 ]] && print_report_info
			# Write values to CSV file
			echocsv "$AWRFILENAME,$PROFILE_DBNAME,$PROFILE_INSTANCENUM,$PROFILE_INSTANCENAME,$PROFILE_DBVERSION,$PROFILE_CLUSTER,$DB_HOSTNAME,$DB_HOST_OS,$DB_NUM_CPUS,$DB_HOST_MEM,$DB_BLOCK_SIZE,$AWR_BEGIN_SNAP,$AWR_BEGIN_TIME,$AWR_END_SNAP,$AWR_END_TIME,$AWR_ELAPSED_TIME,$AWR_DB_TIME,$AWR_AAS,$AWR_BUSY_FLAG,$AWR_LOGICAL_READS,$AWR_BLOCK_CHANGES,$READ_IOPS,$DATA_WRITE_IOPS,$REDO_WRITE_IOPS,$ALL_WRITE_IOPS,$TOTAL_IOPS,$READ_THROUGHPUT,$DATA_WRITE_THROUGHPUT,$REDO_WRITE_THROUGHPUT,$ALL_WRITE_THROUGHPUT,$TOTAL_THROUGHPUT,$AWR_DB_CPU,$AWR_DB_CPU_PCT_DBTIME,$WCLASS_USRIO_NUM_WAITS,$WCLASS_USRIO_WAIT_TIME,$WCLASS_USRIO_AVEWAIT,$WCLASS_USRIO_PCT_DBTIME,$AWR_USER_CALLS,$AWR_PARSES,$AWR_HARD_PARSES,$AWR_LOGONS,$AWR_EXECUTES,$AWR_TRANSACTIONS,$BUFFER_HIT_RATIO,$INMEMORY_SORT_RATIO,$AWR_LOG_SWITCHES_TOTAL,$AWR_LOG_SWITCHES_PERHOUR,$TOP5EVENT1_NAME,$TOP5EVENT1_CLASS,$TOP5EVENT1_WAITS,$TOP5EVENT1_TIME,$TOP5EVENT1_AVERAGE,$TOP5EVENT1_PCT_DBTIME,$TOP5EVENT2_NAME,$TOP5EVENT2_CLASS,$TOP5EVENT2_WAITS,$TOP5EVENT2_TIME,$TOP5EVENT2_AVERAGE,$TOP5EVENT2_PCT_DBTIME,$TOP5EVENT3_NAME,$TOP5EVENT3_CLASS,$TOP5EVENT3_WAITS,$TOP5EVENT3_TIME,$TOP5EVENT3_AVERAGE,$TOP5EVENT3_PCT_DBTIME,$TOP5EVENT4_NAME,$TOP5EVENT4_CLASS,$TOP5EVENT4_WAITS,$TOP5EVENT4_TIME,$TOP5EVENT4_AVERAGE,$TOP5EVENT4_PCT_DBTIME,$TOP5EVENT5_NAME,$TOP5EVENT5_CLASS,$TOP5EVENT5_WAITS,$TOP5EVENT5_TIME,$TOP5EVENT5_AVERAGE,$TOP5EVENT5_PCT_DBTIME,$WAIT_DFSR_WAITS,$WAIT_DFSR_TIME,$WAIT_DFSR_AVERAGE,$WAIT_DFSR_PCT_DBTIME,$WAIT_DFXR_WAITS,$WAIT_DFXR_TIME,$WAIT_DFXR_AVERAGE,$WAIT_DFXR_PCT_DBTIME,$WAIT_DPRD_WAITS,$WAIT_DPRD_TIME,$WAIT_DPRD_AVERAGE,$WAIT_DPRD_PCT_DBTIME,$WAIT_DPWR_WAITS,$WAIT_DPWR_TIME,$WAIT_DPWR_AVERAGE,$WAIT_DPWR_PCT_DBTIME,$WAIT_DPRT_WAITS,$WAIT_DPRT_TIME,$WAIT_DPRT_AVERAGE,$WAIT_DPRT_PCT_DBTIME,$WAIT_DPWT_WAITS,$WAIT_DPWT_TIME,$WAIT_DPWT_AVERAGE,$WAIT_DPWT_PCT_DBTIME,$WAIT_LFSY_WAITS,$WAIT_LFSY_TIME,$WAIT_LFSY_AVERAGE,$WAIT_LFSY_PCT_DBTIME,$WAIT_DFPW_WAITS,$WAIT_DFPW_TIME,$WAIT_DFPW_AVERAGE,$WAIT_DFPW_PCT_DBTIME,$WAIT_LFPW_WAITS,$WAIT_LFPW_TIME,$WAIT_LFPW_AVERAGE,$WAIT_LFPW_PCT_DBTIME,$WAIT_LFSR_WAITS,$WAIT_LFSR_TIME,$WAIT_LFSR_AVERAGE,$WAIT_LFSR_PCT_DBTIME,$OS_BUSY_TIME,$OS_IDLE_TIME,$OS_IOWAIT_TIME,$OS_SYS_TIME,$OS_USER_TIME,$OS_CPU_WAIT_TIME,$OS_RSRC_MGR_WAIT_TIME,$DATA_GUARD_FLAG,$EXADATA_FLAG,$WCLASS_ADMIN_NUM_WAITS,$WCLASS_ADMIN_WAIT_TIME,$WCLASS_ADMIN_AVEWAIT,$WCLASS_ADMIN_PCT_DBTIME,$WCLASS_APPLN_NUM_WAITS,$WCLASS_APPLN_WAIT_TIME,$WCLASS_APPLN_AVEWAIT,$WCLASS_APPLN_PCT_DBTIME,$WCLASS_CLSTR_NUM_WAITS,$WCLASS_CLSTR_WAIT_TIME,$WCLASS_CLSTR_AVEWAIT,$WCLASS_CLSTR_PCT_DBTIME,$WCLASS_COMMT_NUM_WAITS,$WCLASS_COMMT_WAIT_TIME,$WCLASS_COMMT_AVEWAIT,$WCLASS_COMMT_PCT_DBTIME,$WCLASS_CNCUR_NUM_WAITS,$WCLASS_CNCUR_WAIT_TIME,$WCLASS_CNCUR_AVEWAIT,$WCLASS_CNCUR_PCT_DBTIME,$WCLASS_CONFG_NUM_WAITS,$WCLASS_CONFG_WAIT_TIME,$WCLASS_CONFG_AVEWAIT,$WCLASS_CONFG_PCT_DBTIME,$WCLASS_NETWK_NUM_WAITS,$WCLASS_NETWK_WAIT_TIME,$WCLASS_NETWK_AVEWAIT,$WCLASS_NETWK_PCT_DBTIME,$WCLASS_OTHER_NUM_WAITS,$WCLASS_OTHER_WAIT_TIME,$WCLASS_OTHER_AVEWAIT,$WCLASS_OTHER_PCT_DBTIME,$WCLASS_SYSIO_NUM_WAITS,$WCLASS_SYSIO_WAIT_TIME,$WCLASS_SYSIO_AVEWAIT,$WCLASS_SYSIO_PCT_DBTIME"
		else
			# File was not an AWR report
			echoerr "$1 is not an AWR file"
		fi
	else
		# File was not readable so throw error
		echoerr "Cannot read file $1 - ignoring..."
	fi
shift

done

echoinf "No more files found"
# Print summary information
echoinf ""
echoinf "______SUMMARY______"
echoinf "Files found       : $FILECNT"
echoinf "Files processed   : $(($FILECNT - $ERRORCNT))"
echoinf "Processing errors : $ERRORCNT"
echoinf ""

# Calculate exit status and then exit
if   [ "$FILECNT" -eq 0 ]; then
	echoinf "Completed with no files processes"
	exit $EXIT_FAILURE
elif [ "$ERRORCNT" -gt 0 ]; then
	echoinf "Completed with $ERRORCNT errors"
	exit $EXIT_PARTIAL_SUCCESS
else
	echoinf "Completed successfully"
	exit $EXIT_SUCCESS
fi
# EOF
