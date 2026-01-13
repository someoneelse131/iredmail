-- =============================================================================
-- SOGo Database Schema
-- SOGo creates most tables dynamically, but we need the initial view/table
-- =============================================================================

-- SOGo User View (for authentication - connects to vmail.mailbox)
-- This is a view that SOGo uses for user authentication
-- We create it as a table placeholder; actual view is created by SOGo config

-- SOGo Session storage
CREATE TABLE IF NOT EXISTS sogo_sessions_folder (
    c_id VARCHAR(255) NOT NULL,
    c_value TEXT NOT NULL,
    c_creationdate INT NOT NULL,
    c_lastseen INT NOT NULL,
    PRIMARY KEY (c_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- SOGo folder info (required for calendar/contacts)
CREATE TABLE IF NOT EXISTS sogo_folder_info (
    c_folder_id INT NOT NULL AUTO_INCREMENT,
    c_path VARCHAR(255) NOT NULL,
    c_path1 VARCHAR(255) NOT NULL,
    c_path2 VARCHAR(255) DEFAULT NULL,
    c_path3 VARCHAR(255) DEFAULT NULL,
    c_path4 VARCHAR(255) DEFAULT NULL,
    c_foldername VARCHAR(255) NOT NULL,
    c_location VARCHAR(2048) DEFAULT NULL,
    c_quick_location VARCHAR(2048) DEFAULT NULL,
    c_acl_location VARCHAR(2048) DEFAULT NULL,
    c_folder_type VARCHAR(255) NOT NULL,
    PRIMARY KEY (c_folder_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- SOGo defaults storage
CREATE TABLE IF NOT EXISTS sogo_user_profile (
    c_uid VARCHAR(255) NOT NULL,
    c_defaults TEXT,
    c_settings TEXT,
    PRIMARY KEY (c_uid)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- SOGo cache folder
CREATE TABLE IF NOT EXISTS sogo_cache_folder (
    c_uid VARCHAR(255) NOT NULL,
    c_path VARCHAR(255) NOT NULL,
    c_parent_path VARCHAR(255) DEFAULT NULL,
    c_type TINYINT UNSIGNED NOT NULL,
    c_creationdate INT NOT NULL,
    c_lastmodified INT NOT NULL,
    c_version INT NOT NULL DEFAULT 0,
    c_deleted TINYINT UNSIGNED NOT NULL DEFAULT 0,
    c_content TEXT,
    PRIMARY KEY (c_uid, c_path)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- SOGo ACL (Access Control List)
CREATE TABLE IF NOT EXISTS sogo_acl (
    c_folder_id INT NOT NULL,
    c_object VARCHAR(255) NOT NULL,
    c_uid VARCHAR(255) NOT NULL,
    c_role VARCHAR(80) NOT NULL,
    INDEX sogo_acl_folder_id_idx (c_folder_id),
    INDEX sogo_acl_uid_idx (c_uid)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- SOGo Store (for calendar/contacts data)
CREATE TABLE IF NOT EXISTS sogo_store (
    c_folder_id INT NOT NULL,
    c_name VARCHAR(255) NOT NULL,
    c_content TEXT NOT NULL,
    c_creationdate INT NOT NULL,
    c_lastmodified INT NOT NULL,
    c_version INT NOT NULL,
    c_deleted TINYINT UNSIGNED DEFAULT NULL,
    PRIMARY KEY (c_folder_id, c_name)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- SOGo Quick tables (for fast lookups)
-- Calendar quick table
CREATE TABLE IF NOT EXISTS sogo_quick_appointment (
    c_folder_id INT NOT NULL,
    c_name VARCHAR(255) NOT NULL,
    c_uid VARCHAR(255) NOT NULL,
    c_startdate INT DEFAULT NULL,
    c_enddate INT DEFAULT NULL,
    c_cycleenddate INT DEFAULT NULL,
    c_title VARCHAR(1000) NOT NULL DEFAULT '',
    c_participants TEXT,
    c_isallday INT DEFAULT NULL,
    c_iscycle INT DEFAULT NULL,
    c_cycleinfo TEXT,
    c_classification INT NOT NULL,
    c_isopaque INT NOT NULL,
    c_status INT NOT NULL,
    c_priority INT DEFAULT NULL,
    c_location VARCHAR(255) DEFAULT NULL,
    c_orgmail VARCHAR(255) DEFAULT NULL,
    c_partmails TEXT,
    c_partstates TEXT,
    c_category VARCHAR(255) DEFAULT NULL,
    c_sequence INT DEFAULT NULL,
    c_component VARCHAR(10) NOT NULL,
    c_nextalarm INT DEFAULT NULL,
    c_description TEXT,
    PRIMARY KEY (c_folder_id, c_name),
    INDEX sogo_quick_appointment_uid_idx (c_uid),
    INDEX sogo_quick_appointment_start_idx (c_startdate),
    INDEX sogo_quick_appointment_end_idx (c_enddate)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- Contact quick table
CREATE TABLE IF NOT EXISTS sogo_quick_contact (
    c_folder_id INT NOT NULL,
    c_name VARCHAR(255) NOT NULL,
    c_givenname VARCHAR(255) DEFAULT NULL,
    c_cn VARCHAR(255) DEFAULT NULL,
    c_sn VARCHAR(255) DEFAULT NULL,
    c_screenname VARCHAR(255) DEFAULT NULL,
    c_l VARCHAR(255) DEFAULT NULL,
    c_mail VARCHAR(255) DEFAULT NULL,
    c_o VARCHAR(255) DEFAULT NULL,
    c_ou VARCHAR(255) DEFAULT NULL,
    c_telephonenumber VARCHAR(255) DEFAULT NULL,
    c_categories VARCHAR(255) DEFAULT NULL,
    c_component VARCHAR(10) NOT NULL,
    c_hascertificate INT DEFAULT 0,
    PRIMARY KEY (c_folder_id, c_name),
    INDEX sogo_quick_contact_cn_idx (c_cn),
    INDEX sogo_quick_contact_mail_idx (c_mail)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- Alarms table
CREATE TABLE IF NOT EXISTS sogo_alarms_folder (
    c_path VARCHAR(255) NOT NULL,
    c_name VARCHAR(255) NOT NULL,
    c_uid VARCHAR(255) NOT NULL,
    c_recurrence_id INT DEFAULT NULL,
    c_alarm_number INT NOT NULL,
    c_alarm_date INT NOT NULL,
    INDEX sogo_alarms_folder_idx (c_uid, c_recurrence_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
