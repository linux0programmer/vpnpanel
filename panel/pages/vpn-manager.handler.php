<?php

if (!isset($_SESSION["authenticated"]) || $_SESSION["authenticated"] !== true) {
    header("Location: login.php");
    exit();
}

require_once __DIR__ . '/../includes/vpn_helpers.php';
require_once __DIR__ . '/../includes/guard.php';
vp_requireCsrf(false);

$message = '';
$messageType = '';

if (isset($_FILES["config_file"]) && !empty($_FILES["config_file"]["name"])) {
    $configs = vp_loadConfigs();
    $uploadedFile = $_FILES["config_file"];
    $uploadErr    = $uploadedFile['error'] ?? UPLOAD_ERR_NO_FILE;

    if ($uploadErr !== UPLOAD_ERR_OK) {
        $phpUploadErrors = [
            UPLOAD_ERR_INI_SIZE   => 'Файл превышает upload_max_filesize в php.ini',
            UPLOAD_ERR_FORM_SIZE  => 'Файл превышает MAX_FILE_SIZE в форме',
            UPLOAD_ERR_PARTIAL    => 'Файл загружен только частично',
            UPLOAD_ERR_NO_FILE    => 'Файл не выбран',
            UPLOAD_ERR_NO_TMP_DIR => 'Нет временной директории (проверьте /tmp)',
            UPLOAD_ERR_CANT_WRITE => 'Не удалось записать файл на диск',
            UPLOAD_ERR_EXTENSION  => 'Upload заблокирован PHP-расширением',
        ];
        $message = 'Ошибка PHP upload: ' . ($phpUploadErrors[$uploadErr] ?? "код $uploadErr");
        $messageType = 'error';
    } else {
        $originalName = pathinfo($uploadedFile["name"], PATHINFO_FILENAME);
        $extension    = strtolower(pathinfo($uploadedFile["name"], PATHINFO_EXTENSION));
        $maxSize      = 512 * 1024;

        if (count($configs) >= VP_MAX_CONFIGS) {
            $message = "Достигнут лимит " . VP_MAX_CONFIGS . " конфигураций. Удалите старые перед добавлением новых";
            $messageType = "error";
        } elseif (!in_array($extension, ['ovpn', 'conf'], true)) {
            $message = "Разрешены только файлы .ovpn и .conf (ваш: .$extension)";
            $messageType = "error";
        } elseif ($uploadedFile['size'] > $maxSize) {
            $message = "Файл слишком большой (" . round($uploadedFile['size']/1024, 1) . " KB, максимум 512 KB)";
            $messageType = "error";
        } elseif ($uploadedFile['size'] === 0) {
            $message = "Файл пустой";
            $messageType = "error";
        } elseif (!is_dir(VP_CONFIG_PATH)) {
            $message = "Директория " . VP_CONFIG_PATH . " не существует. Запустите sudo bash /var/www/html/update.sh";
            $messageType = "error";
        } elseif (!is_writable(VP_CONFIG_PATH)) {
            $owner = function_exists('posix_getpwuid') ? posix_getpwuid(fileowner(VP_CONFIG_PATH))['name'] : fileowner(VP_CONFIG_PATH);
            $group = function_exists('posix_getgrgid') ? posix_getgrgid(filegroup(VP_CONFIG_PATH))['name'] : filegroup(VP_CONFIG_PATH);
            $perms = substr(sprintf('%o', fileperms(VP_CONFIG_PATH)), -4);
            $message = "Директория " . VP_CONFIG_PATH . " не доступна для записи (владелец=$owner:$group, права=$perms). Выполните: sudo chown root:www-data " . VP_CONFIG_PATH . " && sudo chmod 770 " . VP_CONFIG_PATH;
            $messageType = "error";
        } else {
            $configId     = vp_generateConfigId();
            $savedFile    = $configId . '.' . $extension;
            $savedPath    = VP_CONFIG_PATH . '/' . $savedFile;

            if (!move_uploaded_file($uploadedFile["tmp_name"], $savedPath)) {
                $lastErr = error_get_last();
                $message = "move_uploaded_file не удалось: " . ($lastErr['message'] ?? 'неизвестная причина');
                $messageType = "error";
            } else {
                $configType = vp_detectConfigType($savedPath);
                $configInfo = vp_extractConfigInfo($savedPath, $configType);
                $rawName    = isset($_POST['config_name']) && !empty(trim($_POST['config_name']))
                    ? trim($_POST['config_name']) : $originalName;
                $customName = vp_safeSubstr($rawName, 0, VP_MAX_CONFIG_NAME);

                $maxPriority = 0;
                foreach ($configs as $c) {
                    if (isset($c['priority']) && $c['priority'] > $maxPriority) $maxPriority = $c['priority'];
                }

                $configs[$configId] = [
                    'id'                => $configId,
                    'name'              => $customName,
                    'filename'          => $savedFile,
                    'original_filename' => $uploadedFile["name"],
                    'type'              => $configType,
                    'server'            => $configInfo['server'],
                    'port'              => $configInfo['port'],
                    'protocol'          => $configInfo['protocol'],
                    'priority'          => $maxPriority + 1,
                    'role'              => 'backup',
                    'created_at'        => date('Y-m-d H:i:s'),
                    'last_used'         => null,
                ];

                vp_saveConfigs($configs);
                vp_logEvent('config_added', $configId);
                $message = "Конфигурация '{$customName}' успешно добавлена";
                $messageType = "success";
            }
        }
    }

    $_SESSION['vp_flash'] = ['message' => $message, 'type' => $messageType];
    header('Location: cabinet.php?menu=vpn');
    exit();
}

if (isset($_POST['delete_config'])) {
    $configId = (string)$_POST['delete_config'];
    if (!vp_isValidConfigId($configId)) {
        $message = 'Неверный ID конфига'; $messageType = 'error';
    } else {
        $configs = vp_loadConfigs();
        if (!isset($configs[$configId])) {
            $message = 'Конфиг не найден'; $messageType = 'error';
        } else {
            $vpnState = vp_readState();
            if ($vpnState['ACTIVE_ID'] === $configId) {
                vp_stopAllServices(); vp_disableAllServices(); vp_cleanActiveConfigFiles();
                $newPrimary = ($vpnState['PRIMARY_ID'] === $configId) ? '' : $vpnState['PRIMARY_ID'];
                vp_saveState('stopped', '', $newPrimary, '');
            } elseif ($vpnState['PRIMARY_ID'] === $configId) {
                vp_saveState($vpnState['STATE'], $vpnState['ACTIVE_ID'], '', $vpnState['ACTIVATED_BY']);
            }
            $filePath = VP_CONFIG_PATH . '/' . $configs[$configId]['filename'];
            $nameSnap = $configs[$configId]['name']   ?? '?';
            $serverSnap = $configs[$configId]['server'] ?? '';
            if (file_exists($filePath)) unlink($filePath);
            unset($configs[$configId]);
            vp_saveConfigs($configs);
            vp_logEvent('config_deleted', $configId, $nameSnap, $serverSnap);
            $message = "Конфигурация удалена"; $messageType = "success";
        }
    }

    $_SESSION['vp_flash'] = ['message' => $message, 'type' => $messageType];
    header('Location: cabinet.php?menu=vpn');
    exit();
}
