-- =============================================================================
-- Roundcube Database Schema
-- Based on Roundcube 1.6.x MySQL schema
-- =============================================================================

-- Users table
CREATE TABLE IF NOT EXISTS users (
    user_id INT UNSIGNED NOT NULL AUTO_INCREMENT,
    username VARCHAR(128) NOT NULL,
    mail_host VARCHAR(128) NOT NULL,
    created DATETIME NOT NULL DEFAULT '1000-01-01 00:00:00',
    last_login DATETIME DEFAULT NULL,
    failed_login DATETIME DEFAULT NULL,
    failed_login_counter INT UNSIGNED DEFAULT NULL,
    language VARCHAR(16) DEFAULT NULL,
    preferences LONGTEXT,
    PRIMARY KEY (user_id),
    UNIQUE KEY username (username, mail_host),
    INDEX mail_host_idx (mail_host)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- Identities table
CREATE TABLE IF NOT EXISTS identities (
    identity_id INT UNSIGNED NOT NULL AUTO_INCREMENT,
    user_id INT UNSIGNED NOT NULL,
    changed DATETIME NOT NULL DEFAULT '1000-01-01 00:00:00',
    del TINYINT UNSIGNED NOT NULL DEFAULT 0,
    standard TINYINT UNSIGNED NOT NULL DEFAULT 0,
    name VARCHAR(128) NOT NULL,
    organization VARCHAR(128) NOT NULL DEFAULT '',
    email VARCHAR(128) NOT NULL,
    `reply-to` VARCHAR(128) NOT NULL DEFAULT '',
    bcc VARCHAR(128) NOT NULL DEFAULT '',
    signature LONGTEXT,
    html_signature TINYINT UNSIGNED NOT NULL DEFAULT 0,
    PRIMARY KEY (identity_id),
    INDEX user_identities_idx (user_id, del),
    INDEX email_identities_idx (email, del),
    CONSTRAINT user_id_fk_identities FOREIGN KEY (user_id) REFERENCES users (user_id) ON DELETE CASCADE ON UPDATE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- Collected recipients/addresses
CREATE TABLE IF NOT EXISTS collected_addresses (
    address_id INT UNSIGNED NOT NULL AUTO_INCREMENT,
    user_id INT UNSIGNED NOT NULL,
    changed DATETIME NOT NULL DEFAULT '1000-01-01 00:00:00',
    name VARCHAR(255) NOT NULL DEFAULT '',
    email VARCHAR(255) NOT NULL,
    `type` INT UNSIGNED NOT NULL,
    PRIMARY KEY (address_id),
    UNIQUE KEY user_email_collected_addresses_idx (user_id, `type`, email),
    CONSTRAINT user_id_fk_collected_addresses FOREIGN KEY (user_id) REFERENCES users (user_id) ON DELETE CASCADE ON UPDATE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- Contacts/Addressbook
CREATE TABLE IF NOT EXISTS contacts (
    contact_id INT UNSIGNED NOT NULL AUTO_INCREMENT,
    user_id INT UNSIGNED NOT NULL,
    changed DATETIME NOT NULL DEFAULT '1000-01-01 00:00:00',
    del TINYINT UNSIGNED NOT NULL DEFAULT 0,
    name VARCHAR(128) NOT NULL DEFAULT '',
    email TEXT NOT NULL,
    firstname VARCHAR(128) NOT NULL DEFAULT '',
    surname VARCHAR(128) NOT NULL DEFAULT '',
    vcard LONGTEXT,
    words TEXT,
    PRIMARY KEY (contact_id),
    INDEX user_contacts_idx (user_id, del),
    CONSTRAINT user_id_fk_contacts FOREIGN KEY (user_id) REFERENCES users (user_id) ON DELETE CASCADE ON UPDATE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- Contact groups
CREATE TABLE IF NOT EXISTS contactgroups (
    contactgroup_id INT UNSIGNED NOT NULL AUTO_INCREMENT,
    user_id INT UNSIGNED NOT NULL,
    changed DATETIME NOT NULL DEFAULT '1000-01-01 00:00:00',
    del TINYINT UNSIGNED NOT NULL DEFAULT 0,
    name VARCHAR(128) NOT NULL DEFAULT '',
    PRIMARY KEY (contactgroup_id),
    INDEX user_contactgroups_idx (user_id, del),
    CONSTRAINT user_id_fk_contactgroups FOREIGN KEY (user_id) REFERENCES users (user_id) ON DELETE CASCADE ON UPDATE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- Contact group members
CREATE TABLE IF NOT EXISTS contactgroupmembers (
    contactgroup_id INT UNSIGNED NOT NULL,
    contact_id INT UNSIGNED NOT NULL,
    created DATETIME NOT NULL DEFAULT '1000-01-01 00:00:00',
    PRIMARY KEY (contactgroup_id, contact_id),
    INDEX contactgroupmembers_contact_idx (contact_id),
    CONSTRAINT contactgroup_id_fk_contactgroupmembers FOREIGN KEY (contactgroup_id) REFERENCES contactgroups (contactgroup_id) ON DELETE CASCADE ON UPDATE CASCADE,
    CONSTRAINT contact_id_fk_contactgroupmembers FOREIGN KEY (contact_id) REFERENCES contacts (contact_id) ON DELETE CASCADE ON UPDATE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- Cache tables
CREATE TABLE IF NOT EXISTS cache (
    user_id INT UNSIGNED NOT NULL,
    cache_key VARCHAR(128) NOT NULL,
    expires DATETIME DEFAULT NULL,
    data LONGTEXT NOT NULL,
    PRIMARY KEY (user_id, cache_key),
    INDEX expires_idx (expires),
    CONSTRAINT user_id_fk_cache FOREIGN KEY (user_id) REFERENCES users (user_id) ON DELETE CASCADE ON UPDATE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS cache_shared (
    cache_key VARCHAR(255) NOT NULL,
    expires DATETIME DEFAULT NULL,
    data LONGTEXT NOT NULL,
    PRIMARY KEY (cache_key),
    INDEX expires_idx (expires)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS cache_index (
    user_id INT UNSIGNED NOT NULL,
    mailbox VARCHAR(255) NOT NULL,
    expires DATETIME DEFAULT NULL,
    valid TINYINT UNSIGNED NOT NULL DEFAULT 0,
    data LONGTEXT NOT NULL,
    PRIMARY KEY (user_id, mailbox),
    INDEX expires_idx (expires),
    CONSTRAINT user_id_fk_cache_index FOREIGN KEY (user_id) REFERENCES users (user_id) ON DELETE CASCADE ON UPDATE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS cache_thread (
    user_id INT UNSIGNED NOT NULL,
    mailbox VARCHAR(255) NOT NULL,
    expires DATETIME DEFAULT NULL,
    data LONGTEXT NOT NULL,
    PRIMARY KEY (user_id, mailbox),
    INDEX expires_idx (expires),
    CONSTRAINT user_id_fk_cache_thread FOREIGN KEY (user_id) REFERENCES users (user_id) ON DELETE CASCADE ON UPDATE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS cache_messages (
    user_id INT UNSIGNED NOT NULL,
    mailbox VARCHAR(255) NOT NULL,
    uid INT UNSIGNED NOT NULL,
    expires DATETIME DEFAULT NULL,
    data LONGTEXT NOT NULL,
    flags INT UNSIGNED NOT NULL DEFAULT 0,
    PRIMARY KEY (user_id, mailbox, uid),
    INDEX expires_idx (expires),
    CONSTRAINT user_id_fk_cache_messages FOREIGN KEY (user_id) REFERENCES users (user_id) ON DELETE CASCADE ON UPDATE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- Dictionary (spellcheck personal dictionary)
CREATE TABLE IF NOT EXISTS dictionary (
    user_id INT UNSIGNED DEFAULT NULL,
    `language` VARCHAR(16) NOT NULL,
    data LONGTEXT NOT NULL,
    UNIQUE KEY uniqueness (user_id, `language`),
    CONSTRAINT user_id_fk_dictionary FOREIGN KEY (user_id) REFERENCES users (user_id) ON DELETE CASCADE ON UPDATE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- Saved searches
CREATE TABLE IF NOT EXISTS searches (
    search_id INT UNSIGNED NOT NULL AUTO_INCREMENT,
    user_id INT UNSIGNED NOT NULL,
    `type` TINYINT UNSIGNED NOT NULL DEFAULT 0,
    name VARCHAR(128) NOT NULL,
    data TEXT NOT NULL,
    PRIMARY KEY (search_id),
    UNIQUE KEY uniqueness (user_id, `type`, name),
    CONSTRAINT user_id_fk_searches FOREIGN KEY (user_id) REFERENCES users (user_id) ON DELETE CASCADE ON UPDATE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- Filestore (attachment handling)
CREATE TABLE IF NOT EXISTS filestore (
    file_id INT UNSIGNED NOT NULL AUTO_INCREMENT,
    user_id INT UNSIGNED NOT NULL,
    context VARCHAR(32) NOT NULL,
    filename VARCHAR(128) NOT NULL,
    mtime INT NOT NULL,
    data LONGTEXT NOT NULL,
    PRIMARY KEY (file_id),
    UNIQUE KEY uniqueness (user_id, context, filename),
    CONSTRAINT user_id_fk_filestore FOREIGN KEY (user_id) REFERENCES users (user_id) ON DELETE CASCADE ON UPDATE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- Session storage
CREATE TABLE IF NOT EXISTS session (
    sess_id VARCHAR(128) NOT NULL,
    changed DATETIME NOT NULL DEFAULT '1000-01-01 00:00:00',
    ip VARCHAR(40) NOT NULL,
    vars MEDIUMTEXT NOT NULL,
    PRIMARY KEY (sess_id),
    INDEX changed_idx (changed)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- System settings/key-value storage
CREATE TABLE IF NOT EXISTS system (
    name VARCHAR(64) NOT NULL,
    value MEDIUMTEXT,
    PRIMARY KEY (name)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- Insert initial system value
INSERT IGNORE INTO system (name, value) VALUES ('roundcube-version', '2023101300');

-- Responses (canned responses)
CREATE TABLE IF NOT EXISTS responses (
    response_id INT UNSIGNED NOT NULL AUTO_INCREMENT,
    user_id INT UNSIGNED NOT NULL,
    changed DATETIME NOT NULL DEFAULT '1000-01-01 00:00:00',
    del TINYINT UNSIGNED NOT NULL DEFAULT 0,
    name VARCHAR(255) NOT NULL,
    data LONGTEXT NOT NULL,
    `is_html` TINYINT UNSIGNED NOT NULL DEFAULT 0,
    PRIMARY KEY (response_id),
    INDEX user_responses_idx (user_id, del),
    CONSTRAINT user_id_fk_responses FOREIGN KEY (user_id) REFERENCES users (user_id) ON DELETE CASCADE ON UPDATE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
