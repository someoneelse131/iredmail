<?php
// =============================================================================
// Roundcube Custom Configuration
// This file is included after the main configuration
// =============================================================================

// Proxy settings for Cloudflare/reverse proxy
$config['proxy_whitelist'] = array(
    '172.16.0.0/12',  // Docker networks
    '10.0.0.0/8',     // Private networks
    '192.168.0.0/16', // Private networks
);

// Disable IP check if behind proxy
// $config['ip_check'] = false;

// Custom settings
// $config['product_name'] = 'My Webmail';

// Enable additional plugins
// $config['plugins'] = array_merge($config['plugins'], array(
//     'managesieve',
//     'password',
//     'zipdownload',
// ));

// markasjunk activation. learning_driver=null means plugin only does IMAP
// move — our Dovecot imap_sieve catches that. Avoids double-training.
$config['plugins'] = array_merge(isset($config['plugins']) ? $config['plugins'] : [], ['markasjunk']);
$config['markasjunk_learning_driver'] = null;
$config['markasjunk_spam_mbox']       = 'Junk';
$config['markasjunk_ham_mbox']        = 'INBOX';
