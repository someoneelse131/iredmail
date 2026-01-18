<?php
/**
 * Microsoft Autodiscover handler for Outlook and mobile clients
 * Responds to POST requests with email configuration
 */

// Configuration - these placeholders are replaced during container init
$mailServer = 'HOSTNAME';
$mailDomain = 'FIRST_MAIL_DOMAIN';

// Set response headers
header('Content-Type: application/xml; charset=utf-8');

// Get the raw POST data
$request = file_get_contents('php://input');

// Extract email address from the request
$email = '';
if (!empty($request)) {
    // Parse the XML request to get the email address
    $xml = simplexml_load_string($request);
    if ($xml !== false) {
        // Register namespace for proper parsing
        $xml->registerXPathNamespace('a', 'http://schemas.microsoft.com/exchange/autodiscover/outlook/requestschema/2006');
        $result = $xml->xpath('//a:EMailAddress');
        if (!empty($result)) {
            $email = (string)$result[0];
        }
    }
}

// If no email found in POST, check query string (some clients use GET)
if (empty($email) && isset($_GET['email'])) {
    $email = $_GET['email'];
}

// Default to a placeholder if no email provided
if (empty($email)) {
    $email = 'user@' . $mailDomain;
}

// Output the Autodiscover response
echo '<?xml version="1.0" encoding="utf-8"?>';
?>
<Autodiscover xmlns="http://schemas.microsoft.com/exchange/autodiscover/responseschema/2006">
  <Response xmlns="http://schemas.microsoft.com/exchange/autodiscover/outlook/responseschema/2006a">
    <Account>
      <AccountType>email</AccountType>
      <Action>settings</Action>
      <Protocol>
        <Type>IMAP</Type>
        <Server><?php echo htmlspecialchars($mailServer); ?></Server>
        <Port>993</Port>
        <DomainRequired>off</DomainRequired>
        <LoginName><?php echo htmlspecialchars($email); ?></LoginName>
        <SPA>off</SPA>
        <SSL>on</SSL>
        <AuthRequired>on</AuthRequired>
      </Protocol>
      <Protocol>
        <Type>SMTP</Type>
        <Server><?php echo htmlspecialchars($mailServer); ?></Server>
        <Port>587</Port>
        <DomainRequired>off</DomainRequired>
        <LoginName><?php echo htmlspecialchars($email); ?></LoginName>
        <SPA>off</SPA>
        <Encryption>TLS</Encryption>
        <AuthRequired>on</AuthRequired>
        <UsePOPAuth>on</UsePOPAuth>
        <SMTPLast>off</SMTPLast>
      </Protocol>
    </Account>
  </Response>
</Autodiscover>
