-- =============================================================================
-- iRedAdmin Database Schema
-- Stores admin panel session data, logs, and deleted mailbox tracking
-- =============================================================================

-- Session storage
CREATE TABLE IF NOT EXISTS sessions (
    session_id CHAR(128) NOT NULL PRIMARY KEY,
    atime DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    data TEXT
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- Settings table
CREATE TABLE IF NOT EXISTS settings (
    id BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    account VARCHAR(255) NOT NULL DEFAULT '',
    actual_account VARCHAR(255) NOT NULL DEFAULT '',
    setting VARCHAR(50) NOT NULL DEFAULT '',
    value TEXT,
    UNIQUE KEY (account, setting)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- Tracking table for deleted mailboxes
CREATE TABLE IF NOT EXISTS deleted_mailboxes (
    id BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    timestamp DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    username VARCHAR(255) NOT NULL DEFAULT '',
    domain VARCHAR(255) NOT NULL DEFAULT '',
    maildir VARCHAR(255) NOT NULL DEFAULT '',
    admin VARCHAR(255) NOT NULL DEFAULT '',
    bytes BIGINT(20) NOT NULL DEFAULT 0,
    messages BIGINT(20) NOT NULL DEFAULT 0,
    INDEX (timestamp),
    INDEX (username),
    INDEX (domain),
    INDEX (admin)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- Log table for tracking admin actions
CREATE TABLE IF NOT EXISTS log (
    id BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    timestamp DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    admin VARCHAR(255) NOT NULL DEFAULT '',
    ip VARCHAR(45) NOT NULL DEFAULT '',
    domain VARCHAR(255) NOT NULL DEFAULT '',
    username VARCHAR(255) NOT NULL DEFAULT '',
    event VARCHAR(50) NOT NULL DEFAULT '',
    loglevel VARCHAR(10) NOT NULL DEFAULT 'info',
    msg TEXT,
    INDEX (timestamp),
    INDEX (admin),
    INDEX (domain),
    INDEX (username),
    INDEX (event),
    INDEX (loglevel)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- Update log table (tracks password changes, etc.)
CREATE TABLE IF NOT EXISTS updatelog (
    id BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    date DATE NOT NULL,
    INDEX (date)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
