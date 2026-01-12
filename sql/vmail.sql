-- =============================================================================
-- iRedMail vmail Database Schema
-- =============================================================================

-- Domain table
CREATE TABLE IF NOT EXISTS domain (
    domain VARCHAR(255) NOT NULL PRIMARY KEY,
    description TEXT,
    disclaimer TEXT,
    aliases INT DEFAULT 0,
    mailboxes INT DEFAULT 0,
    maxquota BIGINT DEFAULT 0,
    quota BIGINT DEFAULT 0,
    transport VARCHAR(255) DEFAULT 'dovecot',
    backupmx TINYINT DEFAULT 0,
    settings TEXT,
    created DATETIME DEFAULT NOW(),
    modified DATETIME DEFAULT NOW(),
    expired DATETIME DEFAULT '9999-12-31 00:00:00',
    active TINYINT DEFAULT 1
) ENGINE=InnoDB;

-- Domain admins
CREATE TABLE IF NOT EXISTS domain_admins (
    username VARCHAR(255) NOT NULL,
    domain VARCHAR(255) NOT NULL,
    created DATETIME DEFAULT NOW(),
    active TINYINT DEFAULT 1,
    PRIMARY KEY (username, domain)
) ENGINE=InnoDB;

-- Mailbox table
CREATE TABLE IF NOT EXISTS mailbox (
    username VARCHAR(255) NOT NULL PRIMARY KEY,
    password VARCHAR(255) NOT NULL,
    name VARCHAR(255),
    language VARCHAR(5) DEFAULT 'en_US',
    storagebasedirectory VARCHAR(255) DEFAULT '/var/vmail',
    storagenode VARCHAR(255) DEFAULT 'vmail1',
    maildir VARCHAR(255) NOT NULL,
    quota BIGINT DEFAULT 0,
    domain VARCHAR(255) NOT NULL,
    transport VARCHAR(255) DEFAULT '',
    department VARCHAR(255) DEFAULT '',
    `rank` VARCHAR(255) DEFAULT 'normal',
    employeeid VARCHAR(255) DEFAULT '',
    isadmin TINYINT DEFAULT 0,
    isglobaladmin TINYINT DEFAULT 0,
    enablesmtp TINYINT DEFAULT 1,
    enablesmtpsecured TINYINT DEFAULT 1,
    enablepop3 TINYINT DEFAULT 1,
    enablepop3secured TINYINT DEFAULT 1,
    enablepop3tls TINYINT DEFAULT 1,
    enableimap TINYINT DEFAULT 1,
    enableimapsecured TINYINT DEFAULT 1,
    enableimaptls TINYINT DEFAULT 1,
    enabledeliver TINYINT DEFAULT 1,
    enablelda TINYINT DEFAULT 1,
    enablemanagesieve TINYINT DEFAULT 1,
    enablemanagesievesecured TINYINT DEFAULT 1,
    enablesieve TINYINT DEFAULT 1,
    enablesievesecured TINYINT DEFAULT 1,
    enablesievetls TINYINT DEFAULT 1,
    enableinternal TINYINT DEFAULT 1,
    enabledoveadm TINYINT DEFAULT 1,
    enablelib-storage TINYINT DEFAULT 1,
    enablequota-status TINYINT DEFAULT 1,
    enableindexer-worker TINYINT DEFAULT 1,
    enablelmtp TINYINT DEFAULT 1,
    enabledsync TINYINT DEFAULT 1,
    enablesogowebmail TINYINT DEFAULT 1,
    enablesogocalendar TINYINT DEFAULT 1,
    enablesogoactivesync TINYINT DEFAULT 1,
    allow_nets TEXT,
    disclaimer TEXT,
    settings TEXT,
    passwordlastchange DATETIME DEFAULT NOW(),
    created DATETIME DEFAULT NOW(),
    modified DATETIME DEFAULT NOW(),
    expired DATETIME DEFAULT '9999-12-31 00:00:00',
    active TINYINT DEFAULT 1,
    local_part VARCHAR(255) NOT NULL,
    INDEX (domain),
    INDEX (active)
) ENGINE=InnoDB;

-- Alias table
CREATE TABLE IF NOT EXISTS alias (
    address VARCHAR(255) NOT NULL PRIMARY KEY,
    name VARCHAR(255),
    accesspolicy VARCHAR(30) DEFAULT '',
    domain VARCHAR(255) NOT NULL,
    created DATETIME DEFAULT NOW(),
    modified DATETIME DEFAULT NOW(),
    expired DATETIME DEFAULT '9999-12-31 00:00:00',
    active TINYINT DEFAULT 1,
    INDEX (domain),
    INDEX (active)
) ENGINE=InnoDB;

-- Forwardings table
CREATE TABLE IF NOT EXISTS forwardings (
    id BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    address VARCHAR(255) NOT NULL,
    forwarding VARCHAR(255) NOT NULL,
    domain VARCHAR(255) NOT NULL,
    dest_domain VARCHAR(255) NOT NULL DEFAULT '',
    is_list TINYINT DEFAULT 0,
    is_forwarding TINYINT DEFAULT 0,
    is_alias TINYINT DEFAULT 0,
    is_mailbox TINYINT DEFAULT 0,
    active TINYINT DEFAULT 1,
    UNIQUE KEY (address, forwarding),
    INDEX (domain),
    INDEX (active)
) ENGINE=InnoDB;

-- Alias domain
CREATE TABLE IF NOT EXISTS alias_domain (
    alias_domain VARCHAR(255) NOT NULL PRIMARY KEY,
    target_domain VARCHAR(255) NOT NULL,
    created DATETIME DEFAULT NOW(),
    modified DATETIME DEFAULT NOW(),
    active TINYINT DEFAULT 1,
    INDEX (target_domain),
    INDEX (active)
) ENGINE=InnoDB;

-- Sender BCC
CREATE TABLE IF NOT EXISTS sender_bcc_domain (
    domain VARCHAR(255) NOT NULL PRIMARY KEY,
    bcc_address VARCHAR(255) NOT NULL,
    created DATETIME DEFAULT NOW(),
    modified DATETIME DEFAULT NOW(),
    expired DATETIME DEFAULT '9999-12-31 00:00:00',
    active TINYINT DEFAULT 1
) ENGINE=InnoDB;

CREATE TABLE IF NOT EXISTS sender_bcc_user (
    username VARCHAR(255) NOT NULL PRIMARY KEY,
    bcc_address VARCHAR(255) NOT NULL,
    domain VARCHAR(255) NOT NULL,
    created DATETIME DEFAULT NOW(),
    modified DATETIME DEFAULT NOW(),
    expired DATETIME DEFAULT '9999-12-31 00:00:00',
    active TINYINT DEFAULT 1
) ENGINE=InnoDB;

-- Recipient BCC
CREATE TABLE IF NOT EXISTS recipient_bcc_domain (
    domain VARCHAR(255) NOT NULL PRIMARY KEY,
    bcc_address VARCHAR(255) NOT NULL,
    created DATETIME DEFAULT NOW(),
    modified DATETIME DEFAULT NOW(),
    expired DATETIME DEFAULT '9999-12-31 00:00:00',
    active TINYINT DEFAULT 1
) ENGINE=InnoDB;

CREATE TABLE IF NOT EXISTS recipient_bcc_user (
    username VARCHAR(255) NOT NULL PRIMARY KEY,
    bcc_address VARCHAR(255) NOT NULL,
    domain VARCHAR(255) NOT NULL,
    created DATETIME DEFAULT NOW(),
    modified DATETIME DEFAULT NOW(),
    expired DATETIME DEFAULT '9999-12-31 00:00:00',
    active TINYINT DEFAULT 1
) ENGINE=InnoDB;

-- Used quota
CREATE TABLE IF NOT EXISTS used_quota (
    username VARCHAR(255) NOT NULL PRIMARY KEY,
    bytes BIGINT DEFAULT 0,
    messages BIGINT DEFAULT 0,
    domain VARCHAR(255) NOT NULL DEFAULT ''
) ENGINE=InnoDB;

-- Admin table
CREATE TABLE IF NOT EXISTS admin (
    username VARCHAR(255) NOT NULL PRIMARY KEY,
    password VARCHAR(255) NOT NULL,
    name VARCHAR(255) DEFAULT '',
    language VARCHAR(5) DEFAULT 'en_US',
    passwordlastchange DATETIME DEFAULT NOW(),
    settings TEXT,
    created DATETIME DEFAULT NOW(),
    modified DATETIME DEFAULT NOW(),
    expired DATETIME DEFAULT '9999-12-31 00:00:00',
    active TINYINT DEFAULT 1
) ENGINE=InnoDB;

-- Log table
CREATE TABLE IF NOT EXISTS log (
    id BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    admin VARCHAR(255) NOT NULL,
    domain VARCHAR(255) NOT NULL,
    username VARCHAR(255) NOT NULL,
    loglevel VARCHAR(20) DEFAULT 'info',
    event VARCHAR(255) NOT NULL,
    msg TEXT,
    ip VARCHAR(50) DEFAULT '',
    timestamp DATETIME DEFAULT NOW(),
    INDEX (admin),
    INDEX (domain),
    INDEX (username),
    INDEX (timestamp)
) ENGINE=InnoDB;
