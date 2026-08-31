// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Chinese (`zh`).
class AppLocalizationsZh extends AppLocalizations {
  AppLocalizationsZh([String locale = 'zh']) : super(locale);

  @override
  String get appTitle => 'OpenGlucose';

  @override
  String get settings => '设置';

  @override
  String get cancel => '取消';

  @override
  String get save => '保存';

  @override
  String get saveSettings => '保存设置';

  @override
  String get close => '关闭';

  @override
  String get back => '返回';

  @override
  String get done => '完成';

  @override
  String get continueLabel => '继续';

  @override
  String get skip => '跳过';

  @override
  String get connect => '连接';

  @override
  String get disconnect => '断开连接';

  @override
  String get tryAgain => '重试';

  @override
  String get scanAgain => '重新扫描';

  @override
  String get findMySensor => '查找我的传感器';

  @override
  String get scanning => '正在扫描…';

  @override
  String get nearbySensors => '附近的传感器';

  @override
  String sensorsFound(int count) {
    return '找到 $count 个';
  }

  @override
  String get noSensorsFound => '尚未找到传感器。请将手机靠近传感器，然后重试。';

  @override
  String get exploreSampleData => '查看示例数据';

  @override
  String get sampleDataNotSensor => '示例数据——并非来自传感器';

  @override
  String get sensor => '传感器';

  @override
  String get sensors => '传感器';

  @override
  String get currentSensor => '当前传感器';

  @override
  String get connectSensor => '连接传感器';

  @override
  String get sensorArchive => '传感器归档';

  @override
  String get glucoseAndDisplay => '葡萄糖与显示';

  @override
  String get appleHealth => 'Apple 健康';

  @override
  String get privacyAndData => '隐私与数据';

  @override
  String get aboutOpenGlucose => '关于 OpenGlucose';

  @override
  String get advanced => '高级设置';

  @override
  String get language => '语言';

  @override
  String get appLanguage => '应用语言';

  @override
  String get languageSystem => '跟随设备语言';

  @override
  String get languageSystemDescription => '中文设备使用简体中文，其他设备使用英语。';

  @override
  String get languageEnglish => '英语';

  @override
  String get languageSimplifiedChinese => '简体中文';

  @override
  String get languageSimplifiedChineseNative => '简体中文';

  @override
  String languageCurrent(String language) {
    return '当前：$language';
  }

  @override
  String get languageChangeDescription => '选择 OpenGlucose 使用的语言。此设置不会更改传感器数据。';

  @override
  String get sensorStatusSubtitle => '状态、使用周期、身份和连接';

  @override
  String get noSensorActive => '当前没有活动传感器';

  @override
  String get sensorArchiveSubtitle => '以往传感器会话和导出';

  @override
  String get displaySubtitle => '单位、目标范围和图表样式';

  @override
  String get appleHealthSubtitle => '葡萄糖导出和健康数据控制';

  @override
  String get privacySubtitle => '本地存储和保留';

  @override
  String get aboutSubtitle => '版本、用途和开源项目';

  @override
  String get advancedSubtitle => '诊断和开发者工具';

  @override
  String get history => '历史读数';

  @override
  String get patterns => '趋势';

  @override
  String get weeklyRecap => '每周回顾';

  @override
  String get viewWeeklyRecap => '查看每周回顾';

  @override
  String latestReadingAt(String time) {
    return '最新读数时间：$time';
  }

  @override
  String get supportCodeCopied => '已复制支持代码';

  @override
  String get copySupportCode => '复制支持代码';

  @override
  String get chooseAnotherSensor => '选择其他传感器';

  @override
  String get reviewMove => '检查迁移';

  @override
  String get moveNeedsSupport => '迁移需要支持';

  @override
  String get moveSensorToAnotherPhone => '将传感器连接迁移至另一部手机';

  @override
  String get sensorDetails => '传感器详情';

  @override
  String get serial => '序列号';

  @override
  String get model => '型号';

  @override
  String get firmware => '固件';

  @override
  String get sensorStart => '传感器开始时间';

  @override
  String readingCount(int count) {
    return '$count 条读数';
  }

  @override
  String get showGlucoseInLiveNotification => '在实时通知中显示葡萄糖';

  @override
  String get showGlucoseInLiveNotificationDescription =>
      '允许在 Android 实时通知或 iOS 实时活动中显示葡萄糖读数、趋势和更新时间。任何能查看你锁定屏幕的人都可能看到这些健康数据。';

  @override
  String get showSampleDashboard => '打开示例仪表板';

  @override
  String get sampleDashboard => '示例仪表板';

  @override
  String get openSampleWeeklyRecap => '打开示例每周回顾';

  @override
  String get welcomeTitle => '欢迎使用 OpenGlucose';

  @override
  String get welcomeBody => '一款开源、本地优先的葡萄糖查看工具。专为健康管理、运动和自我探索而设计，不是医疗器械。';

  @override
  String get storedLocallyTitle => '默认存储在本机';

  @override
  String get storedLocallyBody =>
      '历史记录保留在此设备上。只有在你启用时，可选的 Apple 健康或 AI 功能才会共享数据。';

  @override
  String get openSourceTitle => '开源且可扩展';

  @override
  String get openSourceBody => '采用 MIT 许可证。你可以查看、扩展并按自己的方式使用。';

  @override
  String get wellnessDisclaimer =>
      'OpenGlucose 仅供健康管理与自我探索参考，不是医疗器械，也不能替代医疗建议。';

  @override
  String get howItWorksTitle => '工作方式';

  @override
  String get howItWorksBody => '佩戴 Aidex X 传感器，通过蓝牙配对并等待预热完成。之后，读数会直接传输到你的手机。';

  @override
  String get applySensorTitle => '佩戴传感器';

  @override
  String get applySensorBody => '一款一体式小型传感器，最长可佩戴 15 天。';

  @override
  String get warmupTitle => '约 1 小时预热';

  @override
  String get warmupBody => '传感器会在首次读数前自行校准。';

  @override
  String get readingEveryMinuteTitle => '每分钟一条读数';

  @override
  String get readingEveryMinuteBody => '持续更新实时读数和趋势。';

  @override
  String get targetRangeTitle => '设置目标范围';

  @override
  String get targetRangeBody => '选择你希望保持的范围。你随时可以在设置中更改。';

  @override
  String get targetRangeHint => '大多数人从 70–180 mg/dL（约 3.9–10 mmol/L）开始。';

  @override
  String get readyTitle => '已准备就绪';

  @override
  String get readyBody => '请打开 Aidex X 传感器并放在附近。我们会通过蓝牙扫描并连接，然后将显示实时仪表板。';

  @override
  String get turnOnBluetoothTitle => '打开蓝牙';

  @override
  String get turnOnBluetoothBody => '配对期间请将手机靠近传感器。';

  @override
  String get watchItComeAliveTitle => '查看实时数据';

  @override
  String get watchItComeAliveBody => '预热结束后，趋势和读数会立即显示。';

  @override
  String get connectMySensor => '连接我的传感器';

  @override
  String get lifeRemainingUnavailable => '无法获取剩余使用时间';

  @override
  String get sensorExpired => '传感器已到期';

  @override
  String hoursLeft(int count) {
    return '还剩 $count 小时';
  }

  @override
  String daysLeft(int count) {
    return '还剩 $count 天';
  }

  @override
  String get minutesShort => '分钟';

  @override
  String get waitingForFirstReading => '正在等待首次读数';

  @override
  String get warmingUp => '预热中';

  @override
  String get warmupComplete => '预热完成';

  @override
  String get warmup => '预热';

  @override
  String get waiting => '等待中';

  @override
  String get notSyncedYet => '尚未同步';

  @override
  String get syncedJustNow => '刚刚同步';

  @override
  String syncedMinutesAgo(int count) {
    return '$count 分钟前已同步';
  }

  @override
  String syncedHoursAgo(int count) {
    return '$count 小时前已同步';
  }

  @override
  String syncedDaysAgo(int count) {
    return '$count 天前已同步';
  }

  @override
  String get stageError => '出错';

  @override
  String get stageDisconnected => '已断开连接';

  @override
  String get stageReconnecting => '正在重新连接';

  @override
  String get stageSettingUp => '正在设置';

  @override
  String get stageConnected => '已连接';

  @override
  String get stageConnecting => '正在连接';

  @override
  String get stageLive => '实时';

  @override
  String get attentionNeeded => '需要注意';

  @override
  String updatedAt(String time) {
    return '更新于 $time';
  }

  @override
  String get openAppToViewGlucose => '打开应用查看你的葡萄糖读数';

  @override
  String get sensorWarmingUp => '传感器预热中';

  @override
  String get waitingForSensor => '正在等待传感器';

  @override
  String get waitingForGlucoseUpdate => '正在等待葡萄糖更新';

  @override
  String get stale => '数据已过时';

  @override
  String get glucoseUnavailable => '暂无葡萄糖读数';

  @override
  String get bluetoothPermissionRequired =>
      'OpenGlucose 需要蓝牙访问权限。请在手机设置中允许蓝牙及应用请求的附近设备权限。部分手机还需要允许并开启定位服务才能扫描。然后重试。';

  @override
  String get bluetoothOff => '蓝牙已关闭。请在手机快捷设置或设置中打开蓝牙，然后重新扫描。';

  @override
  String get bluetoothUnavailable => '此手机当前无法使用蓝牙。请重启蓝牙或手机后再试。';

  @override
  String get pairingRejected =>
      '手机未完成配对。请将手机靠近传感器，并接受系统配对提示。若此传感器已与另一部手机绑定或连接，请先停止另一部手机上的连接，再重试。请勿重置正在使用的传感器。';

  @override
  String get pairingTimedOut =>
      '配对超时。请将手机靠近传感器，并接受系统配对提示。如果另一部手机正在使用此传感器，请先停止该连接后再试。';

  @override
  String get sensorPossiblyInUse =>
      '传感器在设置过程中变得不可用。它可能超出范围，或已与另一部手机绑定或连接。请将手机靠近传感器，如有需要请停止另一部手机上的连接后再试。请勿重置正在使用的传感器。';

  @override
  String get sensorDisconnected => '传感器已断开连接。请将手机靠近传感器，然后重试。';

  @override
  String get bluetoothSetupTimedOut => '蓝牙设置超时。请将手机靠近传感器，然后重试。';

  @override
  String get bluetoothSetupFailed => '无法完成蓝牙设置。请重启蓝牙后再试。';

  @override
  String get appPurpose =>
      'OpenGlucose 是健康管理/参考软件，不是医疗器械。请勿将其用于诊断、用药或胰岛素剂量、治疗决策或紧急监测。';

  @override
  String get unit => '单位';

  @override
  String get chartStyle => '图表样式';

  @override
  String get targetLow => '目标下限 (mg/dL)';

  @override
  String get targetHigh => '目标上限 (mg/dL)';

  @override
  String get targetRangeInvalid => '请输入递增的目标葡萄糖范围。';

  @override
  String get line => '折线';

  @override
  String get dots => '点';

  @override
  String get candles => '蜡烛图';

  @override
  String get preferencesSection => '偏好设置';

  @override
  String get dataAndIntegrationsSection => '数据与集成';

  @override
  String get appSection => '应用';

  @override
  String archivedSensorsCount(int count) {
    return '$count 个以往传感器';
  }

  @override
  String get aiAndModels => 'AI 与模型';

  @override
  String get noActiveSensor => '没有活动传感器';

  @override
  String get previousDataStaysOnThisPhone => '你以往的数据会保留在此手机上。';

  @override
  String get inactiveSensorExpired =>
      '你的上一枚传感器已到期。此前的读数仍保留在这里——连接新的传感器以继续查看实时葡萄糖。';

  @override
  String get inactiveSensorReplaced =>
      '你的上一枚传感器已更换。此前的读数仍保留在这里——连接新的传感器以继续查看实时葡萄糖。';

  @override
  String get inactiveSensorDisconnected =>
      '当前没有活动传感器。此前的读数仍保留在这里——连接传感器以继续查看实时葡萄糖。';

  @override
  String get inactiveSensorWelcome => '由你掌握自己的葡萄糖数据。连接传感器以查看实时读数和趋势。';

  @override
  String get bluetoothOffTitle => '蓝牙已关闭';

  @override
  String get bluetoothPermissionTitle => '需要蓝牙访问权限';

  @override
  String get bluetoothUnavailableTitle => '蓝牙不可用';

  @override
  String get scanSensorsFailedTitle => '无法扫描传感器';

  @override
  String get scanSensorHelp => '请检查蓝牙，将传感器保持在附近，然后重试。';

  @override
  String get scanSensorHelpShort => '请检查蓝牙后重新扫描。';

  @override
  String get yourGlucoseHistory => '你的葡萄糖历史读数';

  @override
  String get firstReading => '首条读数';

  @override
  String get latestReading => '最新读数';

  @override
  String get storedSessions => '已存储会话';

  @override
  String get historySessionSeparation =>
      '每枚传感器都会在“传感器归档”中保留自己的图表，因此不同会话不会连接成一条线。';

  @override
  String get demoDataWarning => '示例数据——并非真实葡萄糖读数';

  @override
  String lastAt(String time) {
    return '最新时间：$time';
  }

  @override
  String failedToStart(String error) {
    return '启动失败：$error';
  }

  @override
  String counter(int count) {
    return '计数器 $count';
  }

  @override
  String get demoTransport => '示例传输';

  @override
  String get unknownSensorResponse =>
      '传感器响应状态未知。请勿重新连接或在 Android 中取消蓝牙绑定。请联系支持人员，按审核过的恢复步骤操作。';

  @override
  String get reviewInterruptedSensorMove => '检查中断的传感器迁移';

  @override
  String get interruptedSensorMoveReview =>
      '继续前，请打开 Android 蓝牙设置。确认传感器未列为已配对设备。若已列出，请先选择“取消配对”。此操作只会清除应用的安全标记，不会联系传感器或更改蓝牙绑定。';

  @override
  String get interruptedSelectedSensorMoveReview =>
      '请打开 Android 蓝牙设置。确认传感器未列为已配对设备。若已列出，请先选择“取消配对”。继续操作会清除应用的安全标记，并归档此选择。它不会联系传感器或更改蓝牙绑定。';

  @override
  String get checkedBluetooth => '我已检查蓝牙';

  @override
  String get interruptedSensorMoveCouldNotClear => '无法清除中断的传感器迁移。';

  @override
  String get sensorNoLongerActive => '此传感器不再处于活动状态';

  @override
  String get inactiveSensorSettingsDescription => '请返回“设置”查看“传感器归档”，或连接另一枚传感器。';

  @override
  String get backToSettings => '返回设置';

  @override
  String get sensorArchiveEmpty => '传感器到期或更换后，会在此处显示以往的传感器。';

  @override
  String get previousSensor => '以往传感器';

  @override
  String archiveSessionSummary(String reason, String readings, String date) {
    return '$reason · $readings$date';
  }

  @override
  String archiveHistoryOnly(String reason) {
    return '$reason · 仅保留历史读数，未连接';
  }

  @override
  String get readings => '读数';

  @override
  String get started => '开始时间';

  @override
  String get ended => '结束时间';

  @override
  String get recapThisSensor => '查看此传感器的回顾';

  @override
  String get exportData => '导出数据';

  @override
  String get exportArchivedSensorData => '导出已归档传感器数据';

  @override
  String storedGlucoseReadings(int count) {
    return '已存储 $count 条葡萄糖读数';
  }

  @override
  String hiddenWarmupDisclosure(int count) {
    return '完整导出包含 $count 条预热期间的读数。这些读数仍不会显示在图表、回顾和 Apple 健康中。';
  }

  @override
  String get dateRangeUnavailable => '日期范围不可用';

  @override
  String get fileFormat => '文件格式';

  @override
  String get includedInFile => '文件包含内容';

  @override
  String get exportIncludesGlucose => '• 以 mg/dL 和 mmol/L 表示的葡萄糖数值';

  @override
  String get exportIncludesTiming => '• 读数时间、来源和传感器分钟数';

  @override
  String get exportIncludesQuality => '• 原始质量字段和暂定状态';

  @override
  String get exportIncludesArchive => '• 归档原因和会话时间';

  @override
  String get exportExcludesIdentity => '不包含传感器序列号、设备 ID 和存储标识符。';

  @override
  String shareFormat(String format) {
    return '分享 $format';
  }

  @override
  String get csvExportDescription => '最适合导入大多数电子表格和分析应用。';

  @override
  String get txtExportDescription => '制表符分隔的纯文本文件，任何地方都可轻松查看。';

  @override
  String get xlsxExportDescription => '真正的 Excel 工作簿，葡萄糖数值以数字形式存储。';

  @override
  String get archivedSensorExportFailed => '无法导出已归档传感器数据。';

  @override
  String get archiveReasonExpired => '已到期';

  @override
  String get archiveReasonReplaced => '已更换';

  @override
  String get archiveReasonDisconnected => '已断开连接';

  @override
  String get storedInMacAppContainer => '存储在此 Mac 的应用容器中';

  @override
  String get storedOnIphone => '存储在此 iPhone 上';

  @override
  String get localDataMacDescription =>
      '传感器身份和葡萄糖历史记录仅保留在本机。此预览版尚未验证备份排除设置；请检查此 Mac 的备份策略。';

  @override
  String get localDataIphoneDescription => '传感器身份和葡萄糖历史记录仅保留在本机，且不会包含在设备备份中。';

  @override
  String get noOpenGlucoseCloud => '没有 OpenGlucose 云端服务';

  @override
  String get noOpenGlucoseCloudDescription => '只有在你明确启用集成时，数据才会离开应用。';

  @override
  String appVersion(String version) {
    return '版本 $version';
  }

  @override
  String get aboutAppDescription =>
      '一款开源、本地优先的健康管理应用，用于查看你自己的葡萄糖数据。OpenGlucose 不是医疗器械，也不提供诊断或治疗建议。';

  @override
  String get displaySettings => '显示设置';

  @override
  String get targetLowMgdl => '目标下限 (mg/dL)';

  @override
  String get targetHighMgdl => '目标上限 (mg/dL)';

  @override
  String get reviewSelectedInterruptedMove => '检查中断的迁移';

  @override
  String get removeAllSensorPhoneBonds => '移除传感器与所有手机的绑定？';

  @override
  String get moveSensorToAnotherPhoneQuestion => '将传感器迁移到另一部手机？';

  @override
  String get removeAllSensorPhoneBondsDescription =>
      '该传感器只能移除发射器中保存的全部手机绑定。它会与此手机及其他所有手机断开连接，但不会重置传感器会话。请将传感器保持在附近；如出现错误，请勿重试。';

  @override
  String get moveSensorToAnotherPhoneDescription =>
      '此操作会移除传感器与此手机及 Android 的绑定，然后断开连接。不会重置传感器会话。请将传感器保持在附近；如出现错误，请勿重试。';

  @override
  String get moveSensor => '迁移传感器';

  @override
  String get sensorReadyToPairAnotherPhone => '传感器已准备好与另一部手机配对。';

  @override
  String get sensorCannotMoveSafely => '无法安全迁移该传感器。';

  @override
  String get sensorTransferStopped => '传感器迁移已停止。请勿自动重试。';

  @override
  String get developer => '开发者';

  @override
  String get mockScenario => '模拟场景';

  @override
  String get simulatedSensorState => '模拟的传感器状态';

  @override
  String get engineeringControls => '工程控制';

  @override
  String get engineeringControlsDescription => '用于诊断和传感器数据排查的高级校正项。';

  @override
  String get calibrationScale => '校准比例';

  @override
  String get calibrationOffset => '校准偏移量';

  @override
  String get cropFirstSamples => '裁剪前 N 个样本';

  @override
  String get engineeringValuesInvalid => '请输入有效的工程校正值。';

  @override
  String get engineeringSettingsSaved => '工程设置已保存。';

  @override
  String get saveEngineeringSettings => '保存工程设置';

  @override
  String get clearActiveSensorCache => '清除活动传感器缓存';

  @override
  String get clearActiveSensorCacheDescription =>
      '只清除活动传感器的本地缓存。不会删除传感器归档，传感器上的可用读数可能会再次下载。';

  @override
  String get metadata => '元数据';

  @override
  String get diagnostics => '诊断信息';

  @override
  String get noDiagnosticsLoaded => '尚未加载诊断信息。';

  @override
  String get calibrations => '校准记录';

  @override
  String get noCalibrationEntries => '尚未加载校准记录。';

  @override
  String get logs => '日志';

  @override
  String get noLogs => '暂无日志。';

  @override
  String get clearActiveSensorCacheQuestion => '清除活动传感器缓存？';

  @override
  String get clearActiveSensorCacheReview =>
      '这只会移除活动传感器的本地缓存历史记录。已归档传感器会保留，可用读数可能会再次下载。';

  @override
  String get clearCache => '清除缓存';

  @override
  String get activeSensorCacheCleared => '活动传感器缓存已清除。';

  @override
  String get noActiveSensorCacheCleared => '没有活动传感器缓存可清除。';

  @override
  String timeframeHoursShort(int hours) {
    return '$hours小时';
  }

  @override
  String timeframeDaysShort(int days) {
    return '$days天';
  }

  @override
  String get timeframeAll => '全部';

  @override
  String chartMinute(int minute) {
    return '第 $minute 分钟';
  }

  @override
  String chartAxisMinute(int minute) {
    return '第$minute分钟';
  }

  @override
  String get patternsDescription => '用于自我探索的观察结果，不是医疗指标。';

  @override
  String get timeInRange => '范围内时间';

  @override
  String get belowAbove => '低于 / 高于';

  @override
  String get belowAboveRange => '低于 / 高于范围';

  @override
  String get average => '平均值';

  @override
  String get variabilityCv => '波动性（CV）';

  @override
  String get estimatedGmi => '估算 GMI';

  @override
  String get spikes => '高峰次数';

  @override
  String get unavailable => '不可用';

  @override
  String timeInRangeExplanation(String low, String high) {
    return '读数位于 $low 至 $high 之间的比例。';
  }

  @override
  String get belowAboveExplanation => '读数低于下限或高于上限的频率。';

  @override
  String get averageExplanation => '此时间范围内所有读数的平均值。';

  @override
  String variabilityExplanation(String standardDeviation) {
    return '读数围绕平均值的离散程度（标准差 $standardDeviation）。数值较低通常更稳定。';
  }

  @override
  String get estimatedGmiExplanation => '根据 14 天平均葡萄糖得出的粗略指标，不是实验室检测结果。';

  @override
  String spikesExplanation(String high) {
    return '读数超过 $high 的次数。';
  }

  @override
  String patternsInsufficientCoverage(
    String timeframe,
    int readingCount,
    int activeDays,
    int minimumReadings,
    int minimumActiveDays,
  ) {
    return '此 $timeframe 时间范围内的读数还不够。当前有 $readingCount 条读数，覆盖 $activeDays 天；至少需要 $minimumReadings 条读数且覆盖 $minimumActiveDays 天后才会显示趋势。';
  }

  @override
  String get samplePreviewTitle => '查看 OpenGlucose 的工作方式';

  @override
  String get samplePreviewDescription =>
      '此私密预览仅在内存中生成。它不能连接传感器、导出数据、发送通知，也不会与真实葡萄糖历史记录混合。';

  @override
  String get glucoseHistory => '葡萄糖历史读数';

  @override
  String get sampleBadge => '示例';

  @override
  String get sampleWeeklyRecap => '示例每周回顾';

  @override
  String get sensorLifecycle => '传感器使用周期';

  @override
  String get sensorLifecycleUnknownBody => '正在验证传感器会话，暂时无法获取剩余使用时间。';

  @override
  String get active => '运行中';

  @override
  String get expiringSoon => '即将到期';

  @override
  String get expired => '已到期';

  @override
  String get lifeUsed => '已用';

  @override
  String warmupTimeLeft(int minutes) {
    return '还剩 $minutes 分钟';
  }

  @override
  String get sensorAge => '传感器使用时长';

  @override
  String get timeRemaining => '剩余时间';

  @override
  String get totalLife => '总使用期限';

  @override
  String sensorTotalLife(int days) {
    return '$days 天';
  }

  @override
  String get lastSync => '上次同步';

  @override
  String get notYet => '尚未同步';

  @override
  String get justNow => '刚刚';

  @override
  String minutesAgo(int count) {
    return '$count 分钟前';
  }

  @override
  String hoursAgo(int count) {
    return '$count 小时前';
  }

  @override
  String daysAgo(int count) {
    return '$count 天前';
  }

  @override
  String get sensorWarmupLifecycleBanner =>
      '传感器正在预热——首次读数会在第一小时后趋于稳定。请保持传感器佩戴，并让手机靠近传感器。';

  @override
  String sensorExpiringSoonBanner(String remaining) {
    return '此传感器将在 $remaining 后到期。请备好替换传感器，以免错过读数。';
  }

  @override
  String get sensorExpiredDetails =>
      '此传感器已达到 15 天使用期限。以下读数会保留为最后已知值，供你查阅，但不再是实时数据。';

  @override
  String get lastReadingPreservedBelow => '最后一条读数会保留在下方。';

  @override
  String lastReadingAndHistoryPreserved(String time) {
    return '最后一条读数：$time。你的历史记录已保留。';
  }

  @override
  String get nextSteps => '后续步骤';

  @override
  String get replaceExpiredSensorStep => '取下并妥善处置已到期的传感器。';

  @override
  String get applyReplacementSensorStep => '佩戴新的 Aidex X 传感器，并等待约 1 小时预热。';

  @override
  String get startNewSensorSessionStep => '轻点下方按钮以开始新的传感器会话。';

  @override
  String get replaceSensor => '更换传感器';

  @override
  String get weeklyRecapDescription => '过去 7 天的趋势和观察结果——用于自我探索，不是医疗建议。';

  @override
  String get weeklyOverviewTitle => '本周概览';

  @override
  String weeklyOverviewSubtitle(int activeDays, int readingCount) {
    return '7 天中有 $activeDays 天包含读数 · 共 $readingCount 条读数。';
  }

  @override
  String get belowAboveRangeExplanation => '读数低于你的下限和高于你的上限的比例。';

  @override
  String get weeklyAverageExplanation => '本周每条读数的平均值。';

  @override
  String get lowestHighest => '最低 / 最高';

  @override
  String get observedRangeExplanation => '此 7 天时间范围内观察到的范围。';

  @override
  String get variabilityExplanationNoSd => '读数围绕平均值的离散程度。数值较低通常更稳定。';

  @override
  String get dataCoverage => '数据覆盖情况';

  @override
  String get dataCoverageDescription => '此回顾所依据的数据量。';

  @override
  String get timestampedReadingsExplanation => '此 7 天时间范围内带时间戳的读数。';

  @override
  String get daysRepresented => '涵盖天数';

  @override
  String get daysRepresentedExplanation => '至少包含一条读数的日历日。';

  @override
  String get observedSpan => '观察时段';

  @override
  String get observedSpanExplanation => '第一条和最后一条纳入读数之间的时间。';

  @override
  String durationDays(String value) {
    return '$value 天';
  }

  @override
  String durationHours(int value) {
    return '$value 小时';
  }

  @override
  String daysOfSeven(int activeDays) {
    return '共 7 天中的 $activeDays 天';
  }

  @override
  String get versusLastWeek => '与上周相比';

  @override
  String get weekOverWeekChange => '逐周变化。';

  @override
  String previousWeekComparisonDescription(int readingCount, int activeDays) {
    return '上周有 $readingCount 条读数，覆盖 $activeDays 天。只有两周都有足够的数据覆盖时才会显示比较。';
  }

  @override
  String get versusLastWeekDescription => '本周与此前 7 天的比较。';

  @override
  String get noPriorWeek => '无上周数据';

  @override
  String get aboutTheSame => '大致相同';

  @override
  String percentagePoints(String value) {
    return '$value 个百分点';
  }

  @override
  String get daysByTimeInRange => '按范围内时间排序的日期';

  @override
  String get daysByTimeInRangeDescription => '按处于目标范围内的时间排序。';

  @override
  String get mostInRange => '范围内时间最多';

  @override
  String get leastInRange => '范围内时间最少';

  @override
  String weekdayRangeSummary(String day, int percent, String average) {
    return '$day · 范围内 $percent% · 平均 $average';
  }

  @override
  String get topSpikes => '最大上升波动';

  @override
  String get topSpikesDescription => '本周最大的向上波动。';

  @override
  String noSpikesThisWeek(String high) {
    return '本周没有读数超过 $high。';
  }

  @override
  String spikeRiseExplanation(String amount, String baseline) {
    return '从 $baseline 上升了 $amount。';
  }

  @override
  String get weeklyDailyAveragesTitle => '本周每日平均读数';

  @override
  String get weeklyDailyAveragesDescription => '此 7 天时间范围内每天的平均读数。';

  @override
  String get notEnoughReadingsYet => '读数还不够';

  @override
  String weeklyInsufficientCoverage(
    int readingCount,
    int activeDays,
    int minimumReadings,
    int minimumActiveDays,
  ) {
    return '此 7 天时间范围内当前有 $readingCount 条读数，覆盖 $activeDays 天。至少需要 $minimumReadings 条读数且覆盖 $minimumActiveDays 天后才会显示趋势，因此稀疏的历史记录不会被呈现为可靠趋势。';
  }

  @override
  String get weeklyRecapDisclaimer =>
      '这些是用于自我探索的健康观察。OpenGlucose 不是医疗器械，本回顾不构成诊断或医疗建议。请向合格的专业人士咨询健康决策。';

  @override
  String get aiInsights => 'AI 洞察';

  @override
  String get onDeviceModel => '设备端模型';

  @override
  String get onDeviceModelDescription => '已规划 · 使用已下载模型进行私密本地推理';

  @override
  String get comingSoon => '即将推出';

  @override
  String onDeviceModelStatus(String status) {
    return '设备端模型状态：$status';
  }

  @override
  String get aiWellnessPrivacyNotice =>
      '仅供健康管理与自我探索参考，不能用于医疗建议、诊断或剂量决策。除非你明确配置，否则 AI 保持关闭。未来的设备端模型会在本机进行推理；下方的高级云端选项仅发送汇总统计数据，绝不发送原始读数或备注文字。';

  @override
  String get customCloudProvider => '自定义云端服务';

  @override
  String get advancedSendsAggregatesOffDevice => '高级 · 将汇总数据发送到设备外';

  @override
  String get enableCloudAi => '启用云端 AI';

  @override
  String get cloudAiDisabledByDefault => '默认关闭。需要你自己的 API 密钥。';

  @override
  String get apiBaseUrl => 'API 基础 URL';

  @override
  String get aiModel => '模型';

  @override
  String get authScheme => '认证方式';

  @override
  String get authSchemeBearer => 'Bearer（兼容 OpenAI）';

  @override
  String get authSchemeXApiKey => 'x-api-key（Anthropic）';

  @override
  String get apiKeyStoredSecurely => 'API 密钥（安全存储）';

  @override
  String get apiKeySavedMask => '••••••••（已保存）';

  @override
  String get pasteApiKey => '粘贴你的密钥';

  @override
  String get apiKeySavedHint => '已保存密钥。留空即可保留它。';

  @override
  String get apiKeyPlainTextHint => '绝不会以明文方式存储。';

  @override
  String get saveProvider => '保存服务设置';

  @override
  String get removeKey => '移除密钥';

  @override
  String get testWithAggregates => '使用汇总数据测试';

  @override
  String get providerSettingsSaved => '已保存服务设置。';

  @override
  String get apiKeyRemoved => '已移除 API 密钥。';

  @override
  String get savingProviderSettings => '正在保存服务设置…';

  @override
  String get enableCloudAiBeforeTesting => '请先启用云端 AI 再测试。';

  @override
  String get addApiKeyBeforeTesting => '请先添加 API 密钥再测试。';

  @override
  String get generatingAiInsight => '正在生成…';

  @override
  String get aiDisabledOrNoKey => 'AI 已关闭或未设置密钥。';

  @override
  String generatedAndSaved(String title) {
    return '已生成并保存：“$title”。';
  }

  @override
  String get couldNotGenerateAiInsight => '无法生成 AI 洞察。';

  @override
  String get integrations => '集成';

  @override
  String get integrationsIntro => '将你的葡萄糖读数发送到你控制的其他应用。除非你主动开启，否则数据不会离开此设备。';

  @override
  String get appleHealthExportDescription =>
      '当你选择启用并点按“立即同步”后，葡萄糖数值和时间戳会作为血糖样本写入 Apple 健康。若同步中断，重试时可能会写入重复样本。';

  @override
  String get appleHealthOnlyOnIos => 'Apple 健康仅适用于 iOS。';

  @override
  String get appleHealthDisabledWithSimulatedData =>
      '使用模拟或虚拟传感器数据时，Apple 健康导出已禁用。';

  @override
  String get exportToAppleHealth => '导出到 Apple 健康';

  @override
  String get neverSynced => '从未同步';

  @override
  String lastSyncedAt(String time) {
    return '上次同步：$time';
  }

  @override
  String get syncNow => '立即同步';

  @override
  String get appleHealthExportUnavailableInThisMode => '此模式下无法使用 Apple 健康导出。';

  @override
  String get appleHealthAccessNotGranted => '未获得 Apple 健康访问权限。';

  @override
  String get turnOnAppleHealthBeforeSyncing => '请先开启 Apple 健康导出，再同步。';

  @override
  String appleHealthSyncedReadings(int count) {
    return '已同步 $count 条读数。';
  }

  @override
  String appleHealthSyncPartial(int count) {
    return '已同步 $count 条读数，随后导出已停止。';
  }

  @override
  String appleHealthSyncPartialWithReason(int count, String reason) {
    return '已同步 $count 条读数，随后导出已停止：$reason';
  }

  @override
  String get appleHealthAlreadyUpToDate => '已是最新状态。';

  @override
  String get appleHealthExportFailed => '导出失败。';

  @override
  String get appleHealthSampleRejected => 'HealthKit 拒绝了一个葡萄糖样本。';

  @override
  String get appleHealthCouldNotSaveSample => 'Apple 健康无法保存一个葡萄糖样本。';

  @override
  String get appleHealthExportCouldNotComplete => '无法完成 Apple 健康导出。';

  @override
  String get appleHealthWritesDisabled => '此模式下已禁用 Apple 健康写入。';

  @override
  String get macosPreviewLimitations => 'macOS 预览版限制';

  @override
  String get macosTransportPreview => 'macOS 传输预览';

  @override
  String get macosTransportPreviewDescription =>
      '尚未在 Mac 硬件上验证真实 AiDEX 配对、重新连接和实时读数。本构建无法移除系统蓝牙绑定，也不能运行“迁移传感器”。在受控 Mac 测试之前，请先在当前 Android 手机上使用“迁移传感器”操作。';

  @override
  String get aiUnavailableInMacosPreview => 'macOS 预览版中无法使用 AI';

  @override
  String get macosPreviewAiUnavailableDescription =>
      '此临时签名的预览版不具备存储 API 密钥所需的 macOS 钥匙串能力。云端 AI 仍保持关闭。请勿将密钥粘贴到此预览版中。';

  @override
  String get messageWarmupTitle => '预热中';

  @override
  String get messageWarmupBody => '传感器正在稳定。大约一小时后开始显示读数，无需操作。';

  @override
  String get messageTapReadingTitle => '提示';

  @override
  String get messageTapReadingBody => '点按图表中的数据点可查看准确读数和时间。';

  @override
  String get scenarioWarmup => '预热';

  @override
  String get scenarioActiveNormal => '正常运行';

  @override
  String get scenarioActiveHigh => '运行中——高值（提醒）';

  @override
  String get scenarioActiveLow => '运行中——低值（提醒）';

  @override
  String get scenarioRapidRise => '快速上升';

  @override
  String get scenarioRapidFall => '快速下降';

  @override
  String get scenarioExpiringSoon => '即将到期';

  @override
  String get scenarioExpired => '已到期';

  @override
  String get scenarioSignalLoss => '信号丢失';

  @override
  String get scenarioDisconnected => '已断开连接';

  @override
  String get scenarioMultiSensorHistory => '多传感器历史记录';

  @override
  String get scenarioError => '出错';

  @override
  String get scenarioWarmupDescription => '处于约 1 小时的预热期间，尚无读数。';

  @override
  String get scenarioActiveNormalDescription => '葡萄糖处于健康范围内，轻微波动。';

  @override
  String get scenarioActiveHighDescription => '持续高葡萄糖，会触发高值提醒。';

  @override
  String get scenarioActiveLowDescription => '持续低葡萄糖，会触发低值提醒。';

  @override
  String get scenarioRapidRiseDescription => '葡萄糖快速上升（上升趋势）。';

  @override
  String get scenarioRapidFallDescription => '葡萄糖快速下降（下降趋势）。';

  @override
  String get scenarioExpiringSoonDescription => '15 天传感器还剩数小时。';

  @override
  String get scenarioExpiredDescription => '传感器已到期——结束会话状态。';

  @override
  String get scenarioSignalLossDescription => '已连接但信号丢失——读数已过时。';

  @override
  String get scenarioDisconnectedDescription => '已断开连接，但保留最后已知数据。';

  @override
  String get scenarioMultiSensorHistoryDescription => '当前传感器与此前传感器保留的历史记录。';

  @override
  String get scenarioErrorDescription => '严重错误，没有可用数据。';
}
