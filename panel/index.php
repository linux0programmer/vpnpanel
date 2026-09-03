<?php

require_once __DIR__ . '/includes/guard.php';

if (isset($_SESSION["authenticated"]) && $_SESSION["authenticated"] === true) {
    include __DIR__ . '/cabinet.php';
} else {
    include __DIR__ . '/login.php';
}
?>
