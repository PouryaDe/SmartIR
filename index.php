<?php

// Load configuration (including API_DOMAIN and APP_DEBUG)
if (!file_exists(__DIR__ . '/config.php')) {
    die("Configuration file missing. Please reinstall or create config.php");
}
require_once __DIR__ . '/config.php';
require_once __DIR__ . '/Route.php';

// Error reporting based on debug mode set in config.php
$debugMode = defined('APP_DEBUG') && APP_DEBUG;
ini_set('display_errors', $debugMode ? '1' : '0');
ini_set('display_startup_errors', $debugMode ? '1' : '0');
ini_set('log_errors', '1');
ini_set('error_log', __DIR__ . '/error.log');
error_reporting(E_ALL);

// Ensure full UTF-8 encoding across all string and I/O operations
ini_set('default_charset', 'UTF-8');
if (function_exists('mb_internal_encoding')) {
    mb_internal_encoding('UTF-8');
}
if (function_exists('mb_http_output')) {
    mb_http_output('UTF-8');
}

date_default_timezone_set('Asia/Tehran');

// Reject non-GET requests immediately
if (($_SERVER['REQUEST_METHOD'] ?? 'GET') !== 'GET') {
    http_response_code(405);
    header('Allow: GET');
    if (defined('PHPUNIT_RUNNING')) {
        return;
    }
    exit;
}

// ==========================================
// 1. Core Logic Functions
// ==========================================

/**
 * Safely resolves the client's real IP address.
 * Prioritizes Cloudflare connecting IP and public socket address (REMOTE_ADDR)
 * to prevent client-side IP spoofing via X-Forwarded-For.
 *
 * @return string Validated IP address, or empty string if undetermined.
 */
function getClientIp(): string
{
    // If request passed through Cloudflare reverse proxy
    if (!empty($_SERVER['HTTP_CF_CONNECTING_IP'])) {
        $cfIp = trim(explode(',', (string) $_SERVER['HTTP_CF_CONNECTING_IP'])[0]);
        if (filter_var($cfIp, FILTER_VALIDATE_IP)) {
            return $cfIp;
        }
    }

    $remoteAddr = str_replace(["\r", "\n"], '', $_SERVER['REMOTE_ADDR'] ?? '');
    if ($remoteAddr !== '') {
        // If REMOTE_ADDR is a public IP, prioritize it over client-supplied headers
        if (filter_var($remoteAddr, FILTER_VALIDATE_IP, FILTER_FLAG_NO_PRIV_RANGE | FILTER_FLAG_NO_RES_RANGE)) {
            return $remoteAddr;
        }

        // Server is behind an internal reverse proxy / local gateway (e.g. Docker, HAProxy)
        if (!empty($_SERVER['HTTP_X_FORWARDED_FOR'])) {
            $forwardedIps = explode(',', (string) $_SERVER['HTTP_X_FORWARDED_FOR']);
            foreach ($forwardedIps as $candidateIp) {
                $candidateIp = trim($candidateIp);
                if (filter_var($candidateIp, FILTER_VALIDATE_IP)) {
                    return $candidateIp;
                }
            }
        }

        // Fallback to REMOTE_ADDR (even if private) if no forwarded IP was found
        if (filter_var($remoteAddr, FILTER_VALIDATE_IP)) {
            return $remoteAddr;
        }
    }

    return '';
}

/**
 * Determines whether a given User-Agent belongs to a known VPN client/app.
 *
 * @param string $userAgent Raw User-Agent string.
 * @return bool True if recognized as a VPN client.
 */
function isVpnClient(string $userAgent): bool
{
    $ua = strtolower($userAgent);
    $clients = [
        'happ', 'streisand', 'v2ray', 'clash', 'mihomo', 'sing-box',
        'singbox', 'hiddify', 'shadowrocket', 'karing', 'foxray',
        'nekobox', 'nekoray', 'v2box', 'stash', 'loon', 'quantumult', 'surge'
    ];

    foreach ($clients as $client) {
        if (str_contains($ua, $client)) {
            return true;
        }
    }

    return false;
}

/**
 * Determines whether the incoming request originates from a standard web browser.
 *
 * @param string $userAgent    Client User-Agent header.
 * @param string $acceptHeader Client Accept header.
 * @return bool True if the client is a genuine web browser.
 */
function isWebBrowser(string $userAgent, string $acceptHeader): bool
{
    if (isVpnClient($userAgent)) {
        return false;
    }

    $ua     = strtolower($userAgent);
    $accept = strtolower($acceptHeader);

    return str_contains($accept, 'text/html') ||
        (str_contains($ua, 'mozilla') && !str_contains($accept, 'application/json'));
}

/**
 * Fetches JSON data from a given API URL with a 5-minute file-based cache and optional stale fallback.
 *
 * @param string $apiUrl               The full URL of the API endpoint.
 * @param bool   $allowStaleOnFailure  If true, returns stale cached data (up to 24h old) on network/server failures.
 * @return array|null Returns decoded array on success, or null on failure.
 */
function fetchJsonFromUrl(string $apiUrl, bool $allowStaleOnFailure = false): ?array
{
    $userAgent     = str_replace(["\r", "\n"], '', $_SERVER['HTTP_USER_AGENT'] ?? 'PHP-API-Client');
    $cacheDir      = __DIR__ . '/cache/';
    $cacheFile     = $cacheDir . hash('sha256', $apiUrl . '_' . $userAgent) . '_v2.json';
    $cacheLifetime = 300;   // 5 minutes fresh cache
    $staleLifetime = 86400; // 24 hours fallback retention for network disruptions

    // Garbage Collection: Clean up expired cache files (5% probability to avoid performance issues)
    if (random_int(1, 20) === 1 && is_dir($cacheDir)) {
        $files = glob($cacheDir . '*.json');
        if ($files) {
            $now = time();
            $deleted = 0;
            foreach ($files as $file) {
                if (is_file($file) && ($now - (filemtime($file) ?: 0)) >= $staleLifetime) {
                    @unlink($file);
                    if (++$deleted >= 50) {
                        break;
                    }
                }
            }
        }
    }

    $staleCached = null;
    if (file_exists($cacheFile)) {
        $fileMtime = filemtime($cacheFile) ?: 0;
        $fileAge   = time() - $fileMtime;
        $cached    = json_decode((string) file_get_contents($cacheFile), true);

        if (json_last_error() === JSON_ERROR_NONE && isset($cached['headers'], $cached['body'])) {
            if ($fileAge < $cacheLifetime) {
                return $cached;
            }
            if ($fileAge < $staleLifetime) {
                $staleCached = $cached;
            }
        }
    }

    $proxyUrl     = defined('PROXY_URL') ? trim(PROXY_URL) : '';
    $acceptHeader = str_replace(["\r", "\n"], '', $_SERVER['HTTP_ACCEPT'] ?? 'application/json');
    $clientIp     = getClientIp();

    $headersToSend = [
        'Accept: ' . $acceptHeader,
        'Accept-Charset: utf-8',
        'User-Agent: ' . $userAgent,
    ];
    if ($clientIp !== '') {
        $headersToSend[] = 'X-Forwarded-For: ' . $clientIp;
        $headersToSend[] = 'X-Real-IP: ' . $clientIp;
    }

    // Build connection attempts:
    // Attempt 1: Direct connection first (IPv4 prioritized to avoid 5-second IPv6 blackhole hanging in Iranian datacenters)
    $attempts = [
        [
            'use_proxy'       => false,
            'ip_resolve'      => CURL_IPRESOLVE_V4,
            'connect_timeout' => 4,
            'timeout'         => 7,
        ]
    ];

    // Attempt 2: Proxy fallback if configured, otherwise IPv6 fallback if direct IPv4 fails
    if ($proxyUrl !== '') {
        $attempts[] = [
            'use_proxy'       => true,
            'ip_resolve'      => CURL_IPRESOLVE_WHATEVER,
            'connect_timeout' => 5,
            'timeout'         => 10,
        ];
    } else {
        $attempts[] = [
            'use_proxy'       => false,
            'ip_resolve'      => CURL_IPRESOLVE_V6,
            'connect_timeout' => 4,
            'timeout'         => 7,
        ];
    }

    foreach ($attempts as $attempt) {
        $ch = curl_init();
        if ($ch === false) {
            continue;
        }

        $responseHeaders = [];
        curl_setopt($ch, CURLOPT_HEADERFUNCTION, function($curl, $header) use (&$responseHeaders) {
            $len = strlen($header);
            $parts = explode(':', $header, 2);
            if (count($parts) === 2) {
                $name = strtolower(trim($parts[0]));
                $val  = trim($parts[1]);
                // Ensure header value is clean UTF-8
                if (!mb_check_encoding($val, 'UTF-8')) {
                    $val = mb_convert_encoding($val, 'UTF-8', 'ISO-8859-1');
                }
                $responseHeaders[$name][] = $val;
            }
            return $len;
        });

        curl_setopt($ch, CURLOPT_URL, $apiUrl);
        curl_setopt($ch, CURLOPT_RETURNTRANSFER, true);
        curl_setopt($ch, CURLOPT_TIMEOUT, $attempt['timeout']);
        curl_setopt($ch, CURLOPT_CONNECTTIMEOUT, $attempt['connect_timeout']);
        curl_setopt($ch, CURLOPT_FOLLOWLOCATION, true);
        curl_setopt($ch, CURLOPT_MAXREDIRS, 5);
        curl_setopt($ch, CURLOPT_SSL_VERIFYPEER, true);
        curl_setopt($ch, CURLOPT_IPRESOLVE, $attempt['ip_resolve']);
        curl_setopt($ch, CURLOPT_HTTPHEADER, $headersToSend);

        if ($attempt['use_proxy'] && $proxyUrl !== '') {
            curl_setopt($ch, CURLOPT_PROXY, $proxyUrl);
            if (stripos($proxyUrl, 'socks5h://') === 0 || stripos($proxyUrl, 'socks5://') === 0) {
                curl_setopt($ch, CURLOPT_PROXYTYPE, CURLPROXY_SOCKS5_HOSTNAME);
            } elseif (stripos($proxyUrl, 'http://') === 0 || stripos($proxyUrl, 'https://') === 0) {
                curl_setopt($ch, CURLOPT_PROXYTYPE, CURLPROXY_HTTP);
            }
        }

        $response = curl_exec($ch);
        $errno    = curl_errno($ch);
        $httpCode = curl_getinfo($ch, CURLINFO_HTTP_CODE);
        curl_close($ch);

        if (!$errno && $httpCode === 200 && $response) {
            // Strip UTF-8 BOM if present
            if (str_starts_with($response, "\xEF\xBB\xBF")) {
                $response = substr($response, 3);
            }
            if (!mb_check_encoding($response, 'UTF-8')) {
                $response = mb_convert_encoding($response, 'UTF-8', 'auto');
            }

            $data = json_decode($response, true);
            if (json_last_error() === JSON_ERROR_NONE && is_array($data)) {
                $result = [
                    'headers' => $responseHeaders,
                    'body'    => $data
                ];
                if (!is_dir($cacheDir)) {
                    @mkdir($cacheDir, 0775, true);
                }
                $encoded = json_encode($result, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES);
                if ($encoded !== false) {
                    file_put_contents($cacheFile, $encoded, LOCK_EX);
                }
                return $result;
            }
        }
    }

    // Both direct and proxy failed: fall back to stale cache if requested
    if ($allowStaleOnFailure && $staleCached !== null) {
        return $staleCached;
    }

    return null;
}

/**
 * Formats subscription header values to ensure Persian and Unicode characters
 * are never corrupted to '??????' across any VPN client or HTTP library.
 *
 * @param string $headerName Lowercase header name.
 * @param string $headerValue Raw header value.
 * @return array<string, string> Associative array of header_name => header_value.
 */
function formatSubscriptionHeader(string $headerName, string $headerValue): array
{
    // Sanitize header value against CRLF injection / HTTP response splitting
    $headerValue = str_replace(["\r", "\n"], '', trim($headerValue));
    if ($headerValue === '') {
        return [];
    }

    $headerName = strtolower(trim($headerName));
    $headers = [];

    if ($headerName === 'profile-title' || $headerName === 'announce') {
        if (str_starts_with($headerValue, 'base64:')) {
            // Already standard base64: format
            $headers[$headerName] = $headerValue;
            $rawText = base64_decode(substr($headerValue, 7), true);
            if ($rawText !== false && $rawText !== '') {
                $headers[$headerName . '*'] = "UTF-8''" . rawurlencode($rawText);
            }
        } elseif (preg_match('/[^\x20-\x7E]/', $headerValue)) {
            // Contains non-ASCII (Persian / Unicode). Encode to base64: and RFC 8187
            $headers[$headerName] = 'base64:' . base64_encode($headerValue);
            $headers[$headerName . '*'] = "UTF-8''" . rawurlencode($headerValue);
        } elseif (strpos($headerValue, '%') !== false && ($decoded = rawurldecode($headerValue)) !== $headerValue && preg_match('/[^\x20-\x7E]/', $decoded)) {
            // Was percent-encoded Persian/Unicode text
            $headers[$headerName] = 'base64:' . base64_encode($decoded);
            $headers[$headerName . '*'] = "UTF-8''" . rawurlencode($decoded);
        } else {
            // Standard ASCII text
            $headers[$headerName] = $headerValue;
        }
    } elseif ($headerName === 'support-url' || $headerName === 'profile-web-page-url') {
        // Encode non-ASCII characters in URLs to prevent HTTP header corruption
        if (preg_match('/[^\x20-\x7E]/', $headerValue)) {
            $headerValue = preg_replace_callback('/[^\x20-\x7E]+/', function ($matches) {
                return rawurlencode($matches[0]);
            }, $headerValue);
        }
        $headers[$headerName] = $headerValue;
    } else {
        $headers[$headerName] = $headerValue;
    }

    return $headers;
}

/**
 * Normalizes subscription configs to ensure Persian/Unicode remarks (#...)
 * in protocol links (vless, vmess, trojan, ss, etc.) are safe for Java/Android
 * and all client URI parsers without turning into '??????'.
 *
 * @param string $configs Raw subscription configs (plaintext or base64).
 * @return string Normalized configs (base64 encoded for VPN client compatibility).
 */
function normalizeConfigs(string $configs): string
{
    $configs = trim($configs);
    if ($configs === '') {
        return '';
    }

    $isBase64 = false;
    // Check if configs is already base64 encoded
    if (strpos($configs, '://') === false && preg_match('/^[A-Za-z0-9+\/=\r\n]+$/', $configs)) {
        $decoded = base64_decode($configs, true);
        if ($decoded !== false && (strpos($decoded, '://') !== false || strpos($decoded, "\n") !== false)) {
            $configs = $decoded;
            $isBase64 = true;
        }
    }

    // Preserve Clash YAML or Sing-box JSON intact
    $trimmed = ltrim($configs);
    if (str_starts_with($trimmed, '{') || str_starts_with($trimmed, 'proxies:') || str_starts_with($trimmed, 'port:')) {
        return $isBase64 ? base64_encode($configs) : $configs;
    }

    $lines = preg_split('/\r\n|\r|\n/', $configs);
    $normalizedLines = [];

    foreach ($lines as $line) {
        $line = trim($line);
        if ($line === '') {
            continue;
        }

        // Check if this line is a URI with a fragment (#remark)
        if (strpos($line, '://') !== false && strpos($line, '#') !== false) {
            $parts = explode('#', $line, 2);
            $uriPart = $parts[0];
            $remark = $parts[1] ?? '';

            // If remark contains raw non-ASCII characters (e.g. Persian/Arabic/Unicode)
            if ($remark !== '' && preg_match('/[^\x20-\x7E]/', $remark)) {
                $decoded = rawurldecode($remark);
                $remark = rawurlencode($decoded);
            }
            $line = $uriPart . '#' . $remark;
        }

        $normalizedLines[] = $line;
    }

    $result = implode("\n", $normalizedLines);

    // If it contains protocol URIs or was originally base64, return base64
    if ($isBase64 || strpos($result, '://') !== false) {
        return base64_encode($result);
    }

    return $result;
}

/**
 * Renders the HTML redirect page for browser/non-API clients.
 *
 * @param string $url         The redirect destination URL.
 * @param string $finalConfig The subscription config text to output (for API clients).
 */
function renderHtmlRedirect(string $url, string $finalConfig): void
{
    header('Content-Type: text/html; charset=UTF-8');

    $jsUrl   = json_encode($url, JSON_UNESCAPED_UNICODE | JSON_HEX_TAG | JSON_HEX_APOS | JSON_HEX_QUOT | JSON_HEX_AMP);
    $htmlUrl = htmlspecialchars($url, ENT_QUOTES, 'UTF-8');

    echo <<<HTML
<!DOCTYPE html>
<html lang="fa" dir="rtl">
<head>
    <meta charset="UTF-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1.0" />
    <title>در حال انتقال...</title>
    <meta http-equiv="refresh" content="0;url={$htmlUrl}">
    <style>
        html, body { display: none; visibility: hidden; }
    </style>
</head>
<body>
    <script type="text/javascript">
        window.location.replace({$jsUrl});
    </script>
</body>
</html>
HTML;

    if ($finalConfig !== '') {
        echo "\n<!--\n" . normalizeConfigs($finalConfig) . "\n-->\n";
    }
}

/**
 * Main subscription processing orchestrator.
 *
 * @param string $url    The redirect destination URL.
 * @param string $apiUrl The API endpoint to fetch subscription data from.
 */
function processSubscription(string $url, string $apiUrl): void
{
    // Enable allowStaleOnFailure so temporary network hiccups or filtering spikes don't drop configs
    $apiResult = fetchJsonFromUrl($apiUrl, true);

    if ($apiResult !== null && !empty($apiResult['body']['is_valid'])) {
        // Valid VPN client: send specific allowed headers from API
        $allowedHeaders = [
            'subscription-userinfo', 'profile-title', 'profile-update-interval', 
            'announce', 'support-url', 'profile-web-page-url'
        ];
        header('Content-Type: text/plain; charset=UTF-8');
        foreach ($allowedHeaders as $h) {
            if (!empty($apiResult['headers'][$h])) {
                foreach ($apiResult['headers'][$h] as $val) {
                    $formattedHeaders = formatSubscriptionHeader($h, $val);
                    foreach ($formattedHeaders as $headerKey => $headerVal) {
                        header("{$headerKey}: {$headerVal}", false);
                    }
                }
            }
        }
        
        // Output configs (properly normalized and Base64 encoded for VPN clients)
        $configs = (string) ($apiResult['body']['configs'] ?? '');
        echo normalizeConfigs($configs);
        return;
    }

    // If API fetch completely failed and no cache was found:
    if ($apiResult === null) {
        $userAgent = (string) ($_SERVER['HTTP_USER_AGENT'] ?? '');
        $accept    = (string) ($_SERVER['HTTP_ACCEPT'] ?? '');

        if (!isWebBrowser($userAgent, $accept)) {
            // Return 502 to VPN clients and API consumers so apps DO NOT delete existing configs
            http_response_code(502);
            header('Content-Type: text/plain; charset=UTF-8');
            echo "Error 502: Upstream subscription service temporarily unavailable. Please try again shortly.";
            return;
        }
    }

    // Browser or unknown client: render HTML redirect page
    $fallbackConfigs = (string) ($apiResult['body']['configs'] ?? '');
    renderHtmlRedirect($url, $fallbackConfigs);
}

// ==========================================
// 2. Route Definitions
// ==========================================

Route::add('/([\d\w\-]+)', function ($smartlink_id) {
    $queryString = str_replace(["\r", "\n"], '', $_SERVER['QUERY_STRING'] ?? '');
    if ($queryString !== '') {
        $queryString = preg_replace_callback('/[^\x21-\x7E]+/', function ($matches) {
            return rawurlencode($matches[0]);
        }, $queryString);
    }
    $query  = $queryString !== '' ? '?' . $queryString : '';
    $url    = 'https://' . API_DOMAIN . "/{$smartlink_id}/" . $query;
    $apiUrl = 'https://' . API_DOMAIN . "/api/{$smartlink_id}/" . $query;
    processSubscription($url, $apiUrl);
});

Route::add('/', function () {
    http_response_code(204); // No Content
});

Route::pathNotFound(function () {
    http_response_code(404);
});

Route::methodNotAllowed(function () {
    http_response_code(405);
    header('Allow: GET');
});

// Run the router if not in CLI or if explicitly requested
if (php_sapi_name() !== 'cli' || defined('RUN_ROUTER')) {
    Route::run('/');
}
