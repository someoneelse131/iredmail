<?php
/**
 * Mozilla Autoconfig handler - Dynamic multi-domain support
 * Works with Thunderbird, iOS Mail, Android Mail, and other clients
 *
 * Clients request this with ?emailaddress=user@domain.com
 * We extract the domain and return appropriate config
 */

// Configuration - placeholder replaced during container init
$mailServer = 'HOSTNAME';

// Set response headers
header('Content-Type: application/xml; charset=utf-8');

// Extract domain from request
$domain = '';

// Method 1: From emailaddress query parameter (most clients use this)
if (isset($_GET['emailaddress']) && strpos($_GET['emailaddress'], '@') !== false) {
    $parts = explode('@', $_GET['emailaddress']);
    $domain = strtolower(trim($parts[1]));
}

// Method 2: From the Host header (autoconfig.domain.com)
if (empty($domain) && isset($_SERVER['HTTP_HOST'])) {
    $host = strtolower($_SERVER['HTTP_HOST']);
    // Remove port if present
    $host = preg_replace('/:\d+$/', '', $host);

    // If it's autoconfig.domain.com, extract domain.com
    if (preg_match('/^autoconfig\.(.+)$/', $host, $matches)) {
        $domain = $matches[1];
    }
}

// Method 3: From email parameter (alternative format)
if (empty($domain) && isset($_GET['email']) && strpos($_GET['email'], '@') !== false) {
    $parts = explode('@', $_GET['email']);
    $domain = strtolower(trim($parts[1]));
}

// Fallback to primary domain if we couldn't determine it
if (empty($domain)) {
    $domain = 'FIRST_MAIL_DOMAIN';
}

// Sanitize domain for XML output
$domain = htmlspecialchars($domain, ENT_XML1, 'UTF-8');
$mailServer = htmlspecialchars($mailServer, ENT_XML1, 'UTF-8');

// Output XML declaration
echo '<?xml version="1.0" encoding="UTF-8"?>';
?>

<clientConfig version="1.1">
  <emailProvider id="<?php echo $domain; ?>">
    <domain><?php echo $domain; ?></domain>
    <displayName><?php echo $domain; ?> Mail</displayName>
    <displayShortName><?php echo $domain; ?></displayShortName>

    <!-- IMAP (recommended) -->
    <incomingServer type="imap">
      <hostname><?php echo $mailServer; ?></hostname>
      <port>993</port>
      <socketType>SSL</socketType>
      <authentication>password-cleartext</authentication>
      <username>%EMAILADDRESS%</username>
    </incomingServer>

    <!-- IMAP with STARTTLS (alternative) -->
    <incomingServer type="imap">
      <hostname><?php echo $mailServer; ?></hostname>
      <port>143</port>
      <socketType>STARTTLS</socketType>
      <authentication>password-cleartext</authentication>
      <username>%EMAILADDRESS%</username>
    </incomingServer>

    <!-- SMTP Submission -->
    <outgoingServer type="smtp">
      <hostname><?php echo $mailServer; ?></hostname>
      <port>587</port>
      <socketType>STARTTLS</socketType>
      <authentication>password-cleartext</authentication>
      <username>%EMAILADDRESS%</username>
    </outgoingServer>

    <!-- SMTP over SSL (alternative) -->
    <outgoingServer type="smtp">
      <hostname><?php echo $mailServer; ?></hostname>
      <port>465</port>
      <socketType>SSL</socketType>
      <authentication>password-cleartext</authentication>
      <username>%EMAILADDRESS%</username>
    </outgoingServer>

  </emailProvider>
</clientConfig>
