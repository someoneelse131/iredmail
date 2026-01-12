-- =============================================================================
-- Amavisd Database Schema
-- =============================================================================

-- Users table
CREATE TABLE IF NOT EXISTS users (
    id INT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    priority INT DEFAULT 7,
    policy_id INT UNSIGNED DEFAULT NULL,
    email VARBINARY(255) NOT NULL UNIQUE,
    fullname VARCHAR(255) DEFAULT NULL,
    local CHAR(1) DEFAULT NULL
) ENGINE=InnoDB;

-- Policy table
CREATE TABLE IF NOT EXISTS policy (
    id INT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    policy_name VARCHAR(32) DEFAULT NULL,
    virus_lover CHAR(1) DEFAULT NULL,
    spam_lover CHAR(1) DEFAULT NULL,
    unchecked_lover CHAR(1) DEFAULT NULL,
    banned_files_lover CHAR(1) DEFAULT NULL,
    bad_header_lover CHAR(1) DEFAULT NULL,
    bypass_virus_checks CHAR(1) DEFAULT NULL,
    bypass_spam_checks CHAR(1) DEFAULT NULL,
    bypass_banned_checks CHAR(1) DEFAULT NULL,
    bypass_header_checks CHAR(1) DEFAULT NULL,
    virus_quarantine_to VARCHAR(64) DEFAULT NULL,
    spam_quarantine_to VARCHAR(64) DEFAULT NULL,
    banned_quarantine_to VARCHAR(64) DEFAULT NULL,
    unchecked_quarantine_to VARCHAR(64) DEFAULT NULL,
    bad_header_quarantine_to VARCHAR(64) DEFAULT NULL,
    clean_quarantine_to VARCHAR(64) DEFAULT NULL,
    archive_quarantine_to VARCHAR(64) DEFAULT NULL,
    spam_tag_level FLOAT DEFAULT NULL,
    spam_tag2_level FLOAT DEFAULT NULL,
    spam_tag3_level FLOAT DEFAULT NULL,
    spam_kill_level FLOAT DEFAULT NULL,
    spam_dsn_cutoff_level FLOAT DEFAULT NULL,
    spam_quarantine_cutoff_level FLOAT DEFAULT NULL,
    addr_extension_virus VARCHAR(64) DEFAULT NULL,
    addr_extension_spam VARCHAR(64) DEFAULT NULL,
    addr_extension_banned VARCHAR(64) DEFAULT NULL,
    addr_extension_bad_header VARCHAR(64) DEFAULT NULL,
    warnvirusrecip CHAR(1) DEFAULT NULL,
    warnbannedrecip CHAR(1) DEFAULT NULL,
    warnbadhrecip CHAR(1) DEFAULT NULL,
    newvirus_admin VARCHAR(64) DEFAULT NULL,
    virus_admin VARCHAR(64) DEFAULT NULL,
    banned_admin VARCHAR(64) DEFAULT NULL,
    bad_header_admin VARCHAR(64) DEFAULT NULL,
    spam_admin VARCHAR(64) DEFAULT NULL,
    spam_subject_tag VARCHAR(64) DEFAULT NULL,
    spam_subject_tag2 VARCHAR(64) DEFAULT NULL,
    spam_subject_tag3 VARCHAR(64) DEFAULT NULL,
    message_size_limit INT DEFAULT NULL,
    banned_rulenames VARCHAR(64) DEFAULT NULL,
    disclaimer_options VARCHAR(64) DEFAULT NULL,
    forward_method VARCHAR(64) DEFAULT NULL,
    sa_userconf VARCHAR(64) DEFAULT NULL
) ENGINE=InnoDB;

-- Messages table
CREATE TABLE IF NOT EXISTS msgs (
    partition_tag INT DEFAULT 0,
    mail_id VARBINARY(16) NOT NULL,
    secret_id VARBINARY(16) DEFAULT '',
    am_id VARCHAR(20) NOT NULL,
    time_num INT UNSIGNED NOT NULL,
    time_iso CHAR(16) NOT NULL,
    sid INT UNSIGNED NOT NULL,
    policy VARCHAR(255) DEFAULT '',
    client_addr VARCHAR(255) DEFAULT '',
    size INT UNSIGNED NOT NULL,
    originating CHAR(1) DEFAULT '',
    content CHAR(1) DEFAULT '',
    quar_type CHAR(1) DEFAULT '',
    quar_loc VARBINARY(255) DEFAULT '',
    dsn_sent CHAR(1) DEFAULT '',
    spam_level FLOAT DEFAULT NULL,
    message_id VARCHAR(255) DEFAULT '',
    from_addr VARCHAR(255) DEFAULT '',
    subject VARCHAR(255) DEFAULT '',
    host VARCHAR(255) NOT NULL,
    PRIMARY KEY (partition_tag, mail_id),
    INDEX (time_num),
    INDEX (sid)
) ENGINE=InnoDB;

-- Message recipients
CREATE TABLE IF NOT EXISTS msgrcpt (
    partition_tag INT DEFAULT 0,
    mail_id VARBINARY(16) NOT NULL,
    rseqnum INT DEFAULT 0,
    rid INT UNSIGNED NOT NULL,
    is_local CHAR(1) DEFAULT '',
    content CHAR(1) DEFAULT '',
    ds CHAR(1) NOT NULL,
    rs CHAR(1) NOT NULL,
    bl CHAR(1) DEFAULT '',
    wl CHAR(1) DEFAULT '',
    bspam_level FLOAT DEFAULT NULL,
    smtp_resp VARCHAR(255) DEFAULT '',
    PRIMARY KEY (partition_tag, mail_id, rseqnum),
    INDEX (rid)
) ENGINE=InnoDB;

-- Quarantine
CREATE TABLE IF NOT EXISTS quarantine (
    partition_tag INT DEFAULT 0,
    mail_id VARBINARY(16) NOT NULL,
    chunk_ind INT UNSIGNED NOT NULL,
    mail_text BLOB NOT NULL,
    PRIMARY KEY (partition_tag, mail_id, chunk_ind)
) ENGINE=InnoDB;

-- Mailaddr table
CREATE TABLE IF NOT EXISTS mailaddr (
    id INT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    priority INT DEFAULT 7,
    email VARBINARY(255) NOT NULL UNIQUE
) ENGINE=InnoDB;

-- Sender/Recipient ID references
CREATE TABLE IF NOT EXISTS maddr (
    partition_tag INT DEFAULT 0,
    id BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    email VARBINARY(255) NOT NULL,
    domain VARCHAR(255) NOT NULL,
    UNIQUE KEY (partition_tag, email)
) ENGINE=InnoDB;

-- Default policy
INSERT IGNORE INTO policy (id, policy_name) VALUES (1, 'default');
