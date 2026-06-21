-- This query updates the repeat interval to 21,600 seconds (6 hours)
UPDATE scheduler_task_config
SET repeat_interval = 21600
WHERE name = 'Mark Appointment As Missed Task';

-- Run this for the other task as well if needed
UPDATE scheduler_task_config
SET repeat_interval = 21600
WHERE name = 'Mark Appointment As Complete Task';