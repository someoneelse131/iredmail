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

// -----------------------------------------------------------------------------
// SMTP: Einreichung ueber implizites TLS auf 465.
//
// Der generierte Default ist 'localhost:25'. Auf Port 25 wirbt Postfix AUTH
// erst nach STARTTLS (smtpd_tls_auth_only=yes, smtpd_tls_security_level=may),
// und Roundcube schickt bei einem Host ohne Schema kein STARTTLS. Es sieht
// deshalb gar keine AUTH-Faehigkeit und bricht mit "SMTP server does not
// support authentication" ab; die Oberflaeche zeigt das als
// "SMTP Error: Authentication failure". Am 2026-08-25 gemessen, die
// EHLO-Antwort auf 25 ohne STARTTLS enthaelt kein AUTH, nach STARTTLS und auf
// 465 und 587 dagegen "AUTH PLAIN".
//
// Der Hostname muss mail.kirby.rocks lauten, nicht localhost: PHP prueft bei
// ssl:// den Namen im Zertifikat. Im Container loest mail.kirby.rocks auf die
// eigene Container-IP auf, die Verbindung verlaesst den Host also nicht.
//
// Gleiche Ursache und gleiche Loesung wie bei SOGoSMTPServer in sogo.conf,
// dort steht seit laengerem smtps://mail.kirby.rocks:465.
$config['smtp_host'] = 'ssl://mail.kirby.rocks:465';
