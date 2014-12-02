--  show_physical_io.sql : script to display physical IO statistics from DBA_HIST_SYSSTAT
--                         specifically redo size, physical reads and physical writes
--
--  See GitHub repository at https://github.com/flashdba/scripts
--
--  ###########################################################################
--  #                                                                         #
--  # Copyright (C) {2014,2015}  Author: flashdba (http://flashdba.com)       #
--  #                                                                         #
--  # This program is free software; you can redistribute it and/or modify    #
--  # it under the terms of the GNU General Public License as published by    #
--  # the Free Software Foundation; either version 2 of the License, or       #
--  # (at your option) any later version.                                     #
--  #                                                                         #
--  # This program is distributed in the hope that it will be useful,         #
--  # but WITHOUT ANY WARRANTY; without even the implied warranty of          #
--  # MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the           #
--  # GNU General Public License for more details.                            #
--  #                                                                         #
--  # You should have received a copy of the GNU General Public License along #
--  # with this program; if not, write to the Free Software Foundation, Inc., #
--  # 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.             #
--  #                                                                         #
--  ###########################################################################

set lines 140 pages 45
accept num_days prompt 'Enter the number of days to report on [default is 0.5]: '
set verify off

SELECT redo_hist.snap_id AS SnapshotID
,      TO_CHAR(redo_hist.snaptime, 'DD-MON HH24:MI:SS') as SnapshotTime
,      ROUND(redo_hist.statval/elapsed_time/1048576,2) AS Redo_MBsec
,      SUBSTR(RPAD('*', 20 * ROUND ((redo_hist.statval/elapsed_time) / MAX (redo_hist.statval/elapsed_time) OVER (), 2), '*'), 1, 20) AS Redo_Graph
,      ROUND(physical_read_hist.statval/elapsed_time/1048576,2) AS Read_MBsec
,      SUBSTR(RPAD('*', 20 * ROUND ((physical_read_hist.statval/elapsed_time) / MAX (physical_read_hist.statval/elapsed_time) OVER (), 2), '*'), 1, 20) AS Read_Graph
,      ROUND(physical_write_hist.statval/elapsed_time/1048576,2) AS Write_MBsec
,      SUBSTR(RPAD('*', 20 * ROUND ((physical_write_hist.statval/elapsed_time) / MAX (physical_write_hist.statval/elapsed_time) OVER (), 2), '*'), 1, 20) AS Write_Graph
FROM (SELECT s.snap_id
            ,g.value AS stattot
            ,s.end_interval_time AS snaptime
            ,NVL(DECODE(GREATEST(VALUE, NVL(lag (VALUE) OVER (PARTITION BY s.dbid, s.instance_number, g.stat_name 
                 ORDER BY s.snap_id), 0)), VALUE, VALUE - LAG (VALUE) OVER (PARTITION BY s.dbid, s.instance_number, g.stat_name 
                     ORDER BY s.snap_id), VALUE), 0) AS statval
            ,(EXTRACT(day FROM s.end_interval_time)-EXTRACT(day FROM s.begin_interval_time))*86400 +
             (EXTRACT(hour FROM s.end_interval_time)-EXTRACT(hour FROM s.begin_interval_time))*3600 +
             (EXTRACT(minute FROM s.end_interval_time)-EXTRACT(minute FROM s.begin_interval_time))*60 +
             (EXTRACT(second FROM s.end_interval_time)-EXTRACT(second FROM s.begin_interval_time)) as elapsed_time
        FROM dba_hist_snapshot s,
             dba_hist_sysstat g,
             v$instance i 
       WHERE s.snap_id = g.snap_id 
         AND s.begin_interval_time >= sysdate-NVL('&num_days', 0.5)
         AND s.instance_number = i.instance_number 
         AND s.instance_number = g.instance_number 
         AND g.stat_name = 'redo size') redo_hist,
     (SELECT s.snap_id
            ,g.value AS stattot
            ,NVL(DECODE(GREATEST(VALUE, NVL(lag (VALUE) OVER (PARTITION BY s.dbid, s.instance_number, g.stat_name 
                 ORDER BY s.snap_id), 0)), VALUE, VALUE - LAG (VALUE) OVER (PARTITION BY s.dbid, s.instance_number, g.stat_name 
                     ORDER BY s.snap_id), VALUE), 0) AS statval
        FROM dba_hist_snapshot s,
             dba_hist_sysstat g,
             v$instance i 
       WHERE s.snap_id = g.snap_id 
         AND s.begin_interval_time >= sysdate-NVL('&num_days', 0.5)
         AND s.instance_number = i.instance_number 
         AND s.instance_number = g.instance_number 
         AND g.stat_name = 'physical read total bytes') physical_read_hist,
     (SELECT s.snap_id
            ,g.value AS stattot
            ,NVL(DECODE(GREATEST(VALUE, NVL(lag (VALUE) OVER (PARTITION BY s.dbid, s.instance_number, g.stat_name 
                 ORDER BY s.snap_id), 0)), VALUE, VALUE - LAG (VALUE) OVER (PARTITION BY s.dbid, s.instance_number, g.stat_name 
                     ORDER BY s.snap_id), VALUE), 0) AS statval
        FROM dba_hist_snapshot s,
             dba_hist_sysstat g,
             v$instance i 
       WHERE s.snap_id = g.snap_id 
         AND s.begin_interval_time >= sysdate-NVL('&num_days', 0.5)
         AND s.instance_number = i.instance_number 
         AND s.instance_number = g.instance_number 
         AND g.stat_name = 'physical write total bytes') physical_write_hist
WHERE redo_hist.snap_id = physical_read_hist.snap_id
  AND redo_hist.snap_id = physical_write_hist.snap_id
ORDER BY 1;
