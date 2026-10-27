-- Local prototype only: a few employees for people-app's GET /employees/basic-info.
-- Emails match the ThunderID users the One WSO2 dev proxy sends (<sub>@wso2.com), Scott Demo and made-up
-- Demo teammates on Forward Deployed Engineering.
INSERT INTO employment_type (id, name, created_by, updated_by) VALUES (1, 'Permanent', 'seed', 'seed');
INSERT INTO designation (id, designation, job_band, created_by, updated_by) VALUES (1, 'Engineer', 8, 'seed', 'seed');
INSERT INTO company (id, name, prefix, location, created_by, updated_by) VALUES (1, 'WSO2 - US', 'US', 'US', 'seed', 'seed');
INSERT INTO business_unit (id, name, head_email, created_by, updated_by) VALUES (1, 'Corporate', 'bu@wso2.com', 'seed', 'seed');
INSERT INTO team (id, name, head_email, created_by, updated_by) VALUES
  (1, 'Customer Success', 'cs@wso2.com', 'seed', 'seed'),
  (2, 'Marketing', 'mk@wso2.com', 'seed', 'seed');
INSERT INTO sub_team (id, name, head_email, created_by, updated_by) VALUES
  (1, 'Forward Deployed Engineering', 'fde@wso2.com', 'seed', 'seed'),
  (2, 'Support', 'support@wso2.com', 'seed', 'seed');

INSERT INTO personal_info (id, nic_or_passport, first_name, last_name, title, dob, nationality, created_by, updated_by) VALUES
  (1, 'P1', 'Paula', 'Owner', 'Ms', '1990-01-01', 'US', 'seed', 'seed'),
  (2, 'P2', 'Adam', 'Admin', 'Mr', '1990-01-01', 'US', 'seed', 'seed'),
  (3, 'P3', 'Uma', 'User', 'Ms', '1990-01-01', 'US', 'seed', 'seed'),
  (4, 'P4', 'Grace', 'Hopper', 'Ms', '1990-01-01', 'US', 'seed', 'seed'),
  (5, 'P5', 'Alan', 'Turing', 'Mr', '1990-01-01', 'US', 'seed', 'seed'),
  (6, 'P6', 'Lee', 'Leaver', 'Mr', '1990-01-01', 'US', 'seed', 'seed'),
  (7, 'P7', 'Scott', 'Demo', 'Mx', '1990-01-01', 'US', 'seed', 'seed'),
  (8, 'P8', 'Avery', 'Demo', 'Mx', '1990-01-01', 'US', 'seed', 'seed'),
  (9, 'P9', 'Blake', 'Demo', 'Mx', '1990-01-01', 'US', 'seed', 'seed'),
  (10, 'P10', 'Casey', 'Demo', 'Mx', '1990-01-01', 'US', 'seed', 'seed'),
  (11, 'P11', 'Devon', 'Demo', 'Mx', '1990-01-01', 'US', 'seed', 'seed'),
  (12, 'P12', 'Emery', 'Demo', 'Mx', '1990-01-01', 'US', 'seed', 'seed');

INSERT INTO employee (employee_id, first_name, last_name, work_location, work_email, start_date, manager_email,
    employee_status, created_by, updated_by, employment_type_id, designation_id, company_id, team_id, sub_team_id,
    business_unit_id, personal_info_id) VALUES
  ('E-PO',  'Paula', 'Owner',  'US', '01a15208-fb4a-751d-8b8e-a8c218889485@wso2.com', '2024-01-01', 'fde@wso2.com', 'Active', 'seed', 'seed', 1, 1, 1, 1, 1, 1, 1),
  ('E-ADM', 'Adam',  'Admin',  'US', '01900000-0000-7000-8000-000000000030@wso2.com', '2024-01-01', 'fde@wso2.com', 'Active', 'seed', 'seed', 1, 1, 1, 1, 1, 1, 2),
  ('E-USR', 'Uma',   'User',   'US', '01a15209-bf35-7ee1-8e89-5bf9a08e2504@wso2.com', '2024-01-01', 'mk@wso2.com',  'Active', 'seed', 'seed', 1, 1, 1, 2, NULL, 1, 3),
  ('E-101', 'Grace', 'Hopper', 'US', 'grace@wso2.com', '2024-01-01', 'fde@wso2.com', 'Active', 'seed', 'seed', 1, 1, 1, 1, 1, 1, 4),
  ('E-102', 'Alan',  'Turing', 'US', 'alan@wso2.com',  '2024-01-01', 'support@wso2.com', 'Marked leaver', 'seed', 'seed', 1, 1, 1, 1, 2, 1, 5),
  -- Left employees are not in the directory: proves the endpoint's own filter still applies.
  ('E-103', 'Lee',   'Leaver', 'US', 'lee@wso2.com',   '2020-01-01', 'fde@wso2.com', 'Left', 'seed', 'seed', 1, 1, 1, 1, 1, 1, 6),
  ('E-201', 'Scott', 'Demo', 'US', 'scott@wso2.com', '2024-01-01', 'fde@wso2.com', 'Active', 'seed', 'seed', 1, 1, 1, 1, 1, 1, 7),
  ('E-202', 'Avery', 'Demo', 'US', 'avery.demo@wso2.com', '2024-01-01', 'fde@wso2.com', 'Active', 'seed', 'seed', 1, 1, 1, 1, 1, 1, 8),
  ('E-203', 'Blake', 'Demo', 'US', 'blake.demo@wso2.com', '2024-01-01', 'fde@wso2.com', 'Active', 'seed', 'seed', 1, 1, 1, 1, 1, 1, 9),
  ('E-204', 'Casey', 'Demo', 'US', 'casey.demo@wso2.com', '2024-01-01', 'fde@wso2.com', 'Active', 'seed', 'seed', 1, 1, 1, 1, 1, 1, 10),
  ('E-205', 'Devon', 'Demo', 'US', 'devon.demo@wso2.com', '2024-01-01', 'fde@wso2.com', 'Active', 'seed', 'seed', 1, 1, 1, 1, 1, 1, 11),
  ('E-206', 'Emery', 'Demo', 'US', 'emery.demo@wso2.com', '2024-01-01', 'fde@wso2.com', 'Active', 'seed', 'seed', 1, 1, 1, 1, 1, 1, 12);
