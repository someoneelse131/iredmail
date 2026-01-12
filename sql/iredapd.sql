-- =============================================================================
-- iRedAPD Database Schema
-- =============================================================================

-- Greylisting tracking
CREATE TABLE IF NOT EXISTS greylisting_tracking (
    id BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    sender VARCHAR(255) NOT NULL,
    sender_domain VARCHAR(255) NOT NULL,
    rcpt VARCHAR(255) NOT NULL,
    rcpt_domain VARCHAR(255) NOT NULL,
    client_address VARCHAR(40) NOT NULL,
    passed TINYINT DEFAULT 0,
    blocked_count BIGINT DEFAULT 0,
    init_time INT NOT NULL DEFAULT 0,
    last_seen INT NOT NULL DEFAULT 0,
    record_expired INT NOT NULL DEFAULT 0,
    UNIQUE KEY (sender, rcpt, client_address),
    INDEX (sender_domain),
    INDEX (rcpt_domain),
    INDEX (client_address),
    INDEX (record_expired)
) ENGINE=InnoDB;

-- Greylisting whitelist domains
CREATE TABLE IF NOT EXISTS greylisting_whitelist_domains (
    id BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    domain VARCHAR(255) NOT NULL DEFAULT '',
    UNIQUE KEY (domain)
) ENGINE=InnoDB;

-- Greylisting whitelist sender domains
CREATE TABLE IF NOT EXISTS greylisting_whitelist_sender_domains (
    id BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    sender_domain VARCHAR(255) NOT NULL DEFAULT '',
    UNIQUE KEY (sender_domain)
) ENGINE=InnoDB;

-- Throttle
CREATE TABLE IF NOT EXISTS throttle (
    id BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    account VARCHAR(255) NOT NULL,
    kind VARCHAR(10) NOT NULL DEFAULT 'outbound',
    priority TINYINT DEFAULT 0,
    period INT DEFAULT 0,
    msg_size INT DEFAULT 0,
    max_msgs INT DEFAULT 0,
    max_quota INT DEFAULT 0,
    UNIQUE KEY (account, kind)
) ENGINE=InnoDB;

-- Throttle tracking
CREATE TABLE IF NOT EXISTS throttle_tracking (
    id BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    tid BIGINT UNSIGNED NOT NULL,
    account VARCHAR(255) NOT NULL,
    cur_msgs INT DEFAULT 0,
    cur_quota BIGINT DEFAULT 0,
    init_time INT DEFAULT 0,
    last_time INT DEFAULT 0,
    last_notify_time INT DEFAULT 0,
    FOREIGN KEY (tid) REFERENCES throttle(id),
    INDEX (tid),
    INDEX (account)
) ENGINE=InnoDB;

-- Sender / Recipient access control
CREATE TABLE IF NOT EXISTS senderscore_cache (
    id BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    client_address VARCHAR(40) NOT NULL,
    score FLOAT DEFAULT 0,
    time INT NOT NULL DEFAULT 0,
    UNIQUE KEY (client_address)
) ENGINE=InnoDB;

-- SMTP Sessions
CREATE TABLE IF NOT EXISTS smtp_sessions (
    id BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    client_address VARCHAR(40) NOT NULL,
    time_num INT NOT NULL DEFAULT 0,
    init_time INT NOT NULL DEFAULT 0,
    UNIQUE KEY (client_address)
) ENGINE=InnoDB;

-- Settings
CREATE TABLE IF NOT EXISTS settings (
    id BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    account VARCHAR(255) NOT NULL DEFAULT '',
    actual_account VARCHAR(255) NOT NULL DEFAULT '',
    setting VARCHAR(50) NOT NULL DEFAULT '',
    value TEXT,
    UNIQUE KEY (account, setting)
) ENGINE=InnoDB;
