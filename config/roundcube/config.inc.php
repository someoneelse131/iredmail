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
