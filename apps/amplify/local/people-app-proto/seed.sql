-- Local prototype only: the Amplify demo cast for people-app's GET /employees/basic-info.
-- Emails are the Asgardeo demo users' sign-in emails; employee_id is each person's UUID. The head_email
-- columns are placeholders (the first member listed for that group).

INSERT INTO employment_type (id, name, created_by, updated_by) VALUES (1, 'Permanent', 'seed', 'seed');
INSERT INTO designation (id, designation, job_band, created_by, updated_by) VALUES (1, 'Engineer', 8, 'seed', 'seed');
INSERT INTO company (id, name, prefix, location, created_by, updated_by) VALUES (1, 'WSO2 - US', 'US', 'US', 'seed', 'seed');
INSERT INTO business_unit (id, name, head_email, created_by, updated_by) VALUES
  (1, 'PO', 'aloka@wso2.com', 'seed', 'seed'),
  (2, 'SLT', 'harry@wso2.com', 'seed', 'seed'),
  (3, 'CS', 'harsha@wso2.com', 'seed', 'seed'),
  (4, 'MKT', 'thibaut@wso2.com', 'seed', 'seed');
INSERT INTO team (id, name, head_email, created_by, updated_by) VALUES
  (1, 'PO', 'aloka@wso2.com', 'seed', 'seed'),
  (2, 'SLT', 'harry@wso2.com', 'seed', 'seed'),
  (3, 'CS', 'harsha@wso2.com', 'seed', 'seed'),
  (4, 'MKT', 'tori@wso2.com', 'seed', 'seed');
INSERT INTO sub_team (id, name, head_email, created_by, updated_by) VALUES
  (1, 'PO', 'aloka@wso2.com', 'seed', 'seed'),
  (2, 'CEO', 'harry@wso2.com', 'seed', 'seed'),
  (3, 'FDE', 'harsha@wso2.com', 'seed', 'seed'),
  (4, 'CS', 'ruwan@wso2.com', 'seed', 'seed'),
  (5, 'MKT', 'thibaut@wso2.com', 'seed', 'seed'),
  (6, 'TRAIN', 'yohanna@wso2.com', 'seed', 'seed');
-- Replace the default houses with the demo ones.
DELETE FROM house;
INSERT INTO house (id, name) VALUES
  (1, 'Wildbore'),
  (2, 'Orion'),
  (3, 'Pegasus'),
  (4, 'Phoenix'),
  (5, 'Centaurus');

INSERT INTO personal_info (id, nic_or_passport, first_name, last_name, title, dob, nationality, created_by, updated_by) VALUES
  (1, 'P1', 'Aloka', 'Prelis', 'Mx', '1990-01-01', 'US', 'seed', 'seed'),
  (2, 'P2', 'Charuka', 'Thathsarani', 'Mx', '1990-01-01', 'US', 'seed', 'seed'),
  (3, 'P3', 'Eryn', 'Powell', 'Mx', '1990-01-01', 'US', 'seed', 'seed'),
  (4, 'P4', 'Harry', 'Ault', 'Mx', '1990-01-01', 'US', 'seed', 'seed'),
  (5, 'P5', 'Harsha', 'Thirimanna', 'Mx', '1990-01-01', 'US', 'seed', 'seed'),
  (6, 'P6', 'Inthira', 'Satheeskumar', 'Mx', '1990-01-01', 'US', 'seed', 'seed'),
  (7, 'P7', 'Lahiru', 'Sandaruwan', 'Mx', '1990-01-01', 'US', 'seed', 'seed'),
  (8, 'P8', 'Ruwan', 'Linton', 'Mx', '1990-01-01', 'US', 'seed', 'seed'),
  (9, 'P9', 'Scott', 'Bechtel', 'Mx', '1990-01-01', 'US', 'seed', 'seed'),
  (10, 'P10', 'Shashini', 'Konkaduwage', 'Mx', '1990-01-01', 'US', 'seed', 'seed'),
  (11, 'P11', 'Thibaut', 'Rouffineau', 'Mx', '1990-01-01', 'US', 'seed', 'seed'),
  (12, 'P12', 'Tori', 'Jeffcoat', 'Mx', '1990-01-01', 'US', 'seed', 'seed'),
  (13, 'P13', 'Yohanna', 'Fernando', 'Mx', '1990-01-01', 'US', 'seed', 'seed');

INSERT INTO employee (employee_id, first_name, last_name, work_location, work_email, employee_thumbnail, house_id, start_date, manager_email,
    employee_status, created_by, updated_by, employment_type_id, designation_id, company_id, team_id, sub_team_id,
    business_unit_id, personal_info_id) VALUES
  ('dff9b5e5-625f-46fa-b529-2bccf9d89ddc', 'Aloka', 'Prelis', 'US', 'aloka@wso2.com', 'https://wso2.cachefly.net/wso2/sites/all/profile-pics/large/alokap.png', 1, '2024-01-01', 'aloka@wso2.com', 'Active', 'seed', 'seed', 1, 1, 1, 1, 1, 1, 1),
  ('46da2fa6-2c7c-4ff7-8d06-d2de551b2086', 'Charuka', 'Thathsarani', 'US', 'charuka@wso2.com', 'https://wso2.cachefly.net/wso2/sites/all/profile-pics/large/charukat.png', 2, '2024-01-01', 'aloka@wso2.com', 'Active', 'seed', 'seed', 1, 1, 1, 1, 1, 1, 2),
  ('25159b7c-4f54-4ee2-a4d1-52087b978b57', 'Eryn', 'Powell', 'US', 'eryn@wso2.com', 'https://wso2.cachefly.net/wso2/sites/all/profile-pics/large/eryn2025.png', 3, '2024-01-01', 'aloka@wso2.com', 'Active', 'seed', 'seed', 1, 1, 1, 1, 1, 1, 3),
  ('bd2a2f66-08dd-4535-9695-576d8bfdf366', 'Harry', 'Ault', 'US', 'harry@wso2.com', 'https://wso2.cachefly.net/wso2/sites/all/profile-pics/large/harryault2026.png', 2, '2024-01-01', 'harry@wso2.com', 'Active', 'seed', 'seed', 1, 1, 1, 2, 2, 2, 4),
  ('dc6d539b-43f3-4d8a-ac92-0a11ab149e16', 'Harsha', 'Thirimanna', 'US', 'harsha@wso2.com', 'https://wso2.cachefly.net/wso2/sites/all/profile-pics/large/harsha.gif', 1, '2024-01-01', 'harsha@wso2.com', 'Active', 'seed', 'seed', 1, 1, 1, 3, 3, 3, 5),
  ('ae478105-c7d4-4924-9cb7-815b38015eca', 'Inthira', 'Satheeskumar', 'US', 'inthira@wso2.com', 'https://wso2.cachefly.net/wso2/sites/all/profile-pics/large/inthirajanuary2022.png', 1, '2024-01-01', 'aloka@wso2.com', 'Active', 'seed', 'seed', 1, 1, 1, 1, 1, 1, 6),
  ('b7024133-dbc5-46a7-8fa2-f4cb477b884b', 'Lahiru', 'Sandaruwan', 'US', 'lahiru@wso2.com', 'https://wso2.cachefly.net/wso2/sites/all/profile-pics/large/lahirus.gif', 3, '2024-01-01', 'harsha@wso2.com', 'Active', 'seed', 'seed', 1, 1, 1, 3, 3, 3, 7),
  ('504f98ac-ff5b-4586-a6b1-afbc35486543', 'Ruwan', 'Linton', 'US', 'ruwan@wso2.com', 'https://wso2.cachefly.net/wso2/sites/all/profile-pics/large/ruwan.png', 2, '2024-01-01', 'ruwan@wso2.com', 'Active', 'seed', 'seed', 1, 1, 1, 2, 4, 3, 8),
  ('f35b3a67-100d-4281-b25e-af88d444619e', 'Scott', 'Bechtel', 'US', 'scott@wso2.com', 'https://wso2.cachefly.net/wso2/sites/all/profile-pics/large/scott.png', 1, '2024-01-01', 'harsha@wso2.com', 'Active', 'seed', 'seed', 1, 1, 1, 3, 3, 3, 9),
  ('8b1c1aa5-e21d-4895-af82-02e28efb7303', 'Shashini', 'Konkaduwage', 'US', 'shashini@wso2.com', 'https://wso2.cachefly.net/wso2/sites/all/profile-pics/large/shashini2026.png', 2, '2024-01-01', 'aloka@wso2.com', 'Active', 'seed', 'seed', 1, 1, 1, 1, 1, 1, 10),
  ('8bf1543b-f685-4f2d-ba54-48bac01bc0e1', 'Thibaut', 'Rouffineau', 'US', 'thibaut@wso2.com', 'https://wso2.cachefly.net/wso2/sites/all/profile-pics/large/thibaut2026.png', 3, '2024-01-01', 'thibaut@wso2.com', 'Active', 'seed', 'seed', 1, 1, 1, 2, 5, 4, 11),
  ('8280b9be-c80d-4ef9-aab5-e096f176e2ef', 'Tori', 'Jeffcoat', 'US', 'tori@wso2.com', 'https://wso2.cachefly.net/wso2/sites/all/profile-pics/large/victoriaj2026.png', 3, '2024-01-01', 'thibaut@wso2.com', 'Active', 'seed', 'seed', 1, 1, 1, 4, 5, 4, 12),
  ('4fa1d099-d0ed-4396-8625-3b29dfc28d52', 'Yohanna', 'Fernando', 'US', 'yohanna@wso2.com', 'https://wso2.cachefly.net/wso2/sites/all/profile-pics/large/yohanna.png', 3, '2024-01-01', 'yohanna@wso2.com', 'Active', 'seed', 'seed', 1, 1, 1, 4, 6, 4, 13);
