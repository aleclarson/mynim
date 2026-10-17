## Updater translations from MyGo revision
## 7e8688284e4b1fc752169ed9db5f51a5f213a2e6.

import std/[algorithm, strutils, tables]

import mynim/plugins/updater/frontend as frontend
import mynim/plugins/updater/markdown as markdown

type
  Strings* = object
    title*, menuItem*, checking*, cancel*: string
    ok*, upToDate*, upToDateMessage*, unavailable*: string
    unavailableMessage*, developmentBuild*, error*, checkError*: string
    installError*, available*, availableMessage*, releaseNotes*: string
    automaticDownloads*, skip*, remindLater*, install*: string
    downloading*, progress*, megabytes*, installing*: string
    ready*, readyMessage*, later*, relaunch*: string

let english* = Strings(
  title: "Software Update",
  menuItem: "Check for Updates…",
  checking: "Checking for updates…",
  cancel: "Cancel",
  ok: "OK",
  upToDate: "You’re up to date!",
  upToDateMessage: "%[1]s %[2]s is currently the newest version available.",
  unavailable: "Updates Unavailable",
  unavailableMessage: "%[1]s cannot update itself where it is installed. If a package manager installed it, update it there.",
  developmentBuild: "Development builds do not update themselves.",
  error: "Update Error!",
  checkError: "An error occurred while checking for updates. Please try again later.",
  installError: "An error occurred while installing the update. Please try again later.",
  available: "A new version of %[1]s is available!",
  availableMessage: "%[1]s %[2]s is now available—you have %[3]s. Would you like to install it now?",
  releaseNotes: "Release Notes:",
  automaticDownloads: "Automatically download and install updates in the future",
  skip: "Skip This Version",
  remindLater: "Remind Me Later",
  install: "Install Update",
  downloading: "Downloading update…",
  progress: "%[1]s of %[2]s",
  megabytes: "%s MB",
  installing: "Installing update…",
  ready: "Ready to Relaunch",
  readyMessage: "%[1]s %[2]s is installed and starts the next time you open %[1]s. Relaunch now to start using it.",
  later: "Later",
  relaunch: "Relaunch Now"
)

let translations* = block:
  var catalog = initTable[string, Strings]()
  catalog["de"] = Strings(
    title: "Softwareaktualisierung",
    menuItem: "Nach Updates suchen …",
    checking: "Suche nach Updates …",
    cancel: "Abbrechen",
    ok: "OK",
    upToDate: "Sie sind auf dem neuesten Stand!",
    upToDateMessage: "%[1]s %[2]s ist derzeit die neueste verfügbare Version.",
    unavailable: "Updates nicht verfügbar",
    unavailableMessage: "%[1]s kann sich an seinem Installationsort nicht selbst aktualisieren. Wurde es mit einer Paketverwaltung installiert, aktualisieren Sie es dort.",
    developmentBuild: "Entwicklungs-Builds aktualisieren sich nicht selbst.",
    error: "Fehler beim Update!",
    checkError: "Beim Suchen nach Updates ist ein Fehler aufgetreten. Bitte versuchen Sie es später erneut.",
    installError: "Beim Installieren des Updates ist ein Fehler aufgetreten. Bitte versuchen Sie es später erneut.",
    available: "Eine neue Version von %[1]s ist verfügbar!",
    availableMessage: "%[1]s %[2]s ist jetzt verfügbar – Sie haben %[3]s. Möchten Sie es jetzt installieren?",
    releaseNotes: "Versionshinweise:",
    automaticDownloads: "Updates künftig automatisch laden und installieren",
    skip: "Diese Version überspringen",
    remindLater: "Später erinnern",
    install: "Update installieren",
    downloading: "Update wird geladen …",
    progress: "%[1]s von %[2]s",
    megabytes: "%s MB",
    installing: "Update wird installiert …",
    ready: "Bereit zum Neustart",
    readyMessage: "%[1]s %[2]s ist installiert und startet, wenn Sie %[1]s das nächste Mal öffnen. Starten Sie jetzt neu, um es zu verwenden.",
    later: "Später",
    relaunch: "Jetzt neu starten"
  )
  catalog["es"] = Strings(
    title: "Actualización de software",
    menuItem: "Buscar actualizaciones…",
    checking: "Buscando actualizaciones…",
    cancel: "Cancelar",
    ok: "Aceptar",
    upToDate: "¡Ya tiene la versión más reciente!",
    upToDateMessage: "%[1]s %[2]s es la versión más reciente disponible.",
    unavailable: "Actualizaciones no disponibles",
    unavailableMessage: "%[1]s no puede actualizarse en la ubicación donde está instalado. Si lo instaló un gestor de paquetes, actualícelo desde allí.",
    developmentBuild: "Las versiones de desarrollo no se actualizan solas.",
    error: "¡Error de actualización!",
    checkError: "Se ha producido un error al buscar actualizaciones. Vuelva a intentarlo más tarde.",
    installError: "Se ha producido un error al instalar la actualización. Vuelva a intentarlo más tarde.",
    available: "¡Hay una nueva versión de %[1]s disponible!",
    availableMessage: "%[1]s %[2]s ya está disponible (tiene la versión %[3]s). ¿Desea instalarla ahora?",
    releaseNotes: "Notas de la versión:",
    automaticDownloads: "Descargar e instalar actualizaciones automáticamente en el futuro",
    skip: "Omitir esta versión",
    remindLater: "Recordármelo más tarde",
    install: "Instalar actualización",
    downloading: "Descargando actualización…",
    progress: "%[1]s de %[2]s",
    megabytes: "%s MB",
    installing: "Instalando actualización…",
    ready: "Listo para reiniciar",
    readyMessage: "%[1]s %[2]s está instalado y se abrirá la próxima vez que inicie %[1]s. Reinicie ahora para empezar a usarlo.",
    later: "Más tarde",
    relaunch: "Reiniciar ahora"
  )
  catalog["fr"] = Strings(
    title: "Mise à jour de logiciels",
    menuItem: "Rechercher les mises à jour…",
    checking: "Recherche de mises à jour…",
    cancel: "Annuler",
    ok: "OK",
    upToDate: "Vous êtes à jour !",
    upToDateMessage: "%[1]s %[2]s est actuellement la version la plus récente.",
    unavailable: "Mises à jour indisponibles",
    unavailableMessage: "%[1]s ne peut pas se mettre à jour à l’emplacement où il est installé. S’il a été installé par un gestionnaire de paquets, mettez-le à jour depuis celui-ci.",
    developmentBuild: "Les versions de développement ne se mettent pas à jour.",
    error: "Erreur de mise à jour !",
    checkError: "Une erreur est survenue lors de la recherche de mises à jour. Veuillez réessayer plus tard.",
    installError: "Une erreur est survenue lors de l’installation de la mise à jour. Veuillez réessayer plus tard.",
    available: "Une nouvelle version de %[1]s est disponible !",
    availableMessage: "%[1]s %[2]s est maintenant disponible (vous avez la version %[3]s). Voulez-vous l’installer maintenant ?",
    releaseNotes: "Notes de version :",
    automaticDownloads: "Télécharger et installer automatiquement les mises à jour à l’avenir",
    skip: "Ignorer cette version",
    remindLater: "Me le rappeler plus tard",
    install: "Installer la mise à jour",
    downloading: "Téléchargement de la mise à jour…",
    progress: "%[1]s sur %[2]s",
    megabytes: "%s Mo",
    installing: "Installation de la mise à jour…",
    ready: "Prêt à relancer",
    readyMessage: "%[1]s %[2]s est installé et démarrera la prochaine fois que vous ouvrirez %[1]s. Relancez maintenant pour l’utiliser.",
    later: "Plus tard",
    relaunch: "Relancer maintenant"
  )
  catalog["it"] = Strings(
    title: "Aggiornamento software",
    menuItem: "Controlla aggiornamenti…",
    checking: "Ricerca di aggiornamenti…",
    cancel: "Annulla",
    ok: "OK",
    upToDate: "Hai già l’ultima versione!",
    upToDateMessage: "%[1]s %[2]s è attualmente la versione più recente disponibile.",
    unavailable: "Aggiornamenti non disponibili",
    unavailableMessage: "%[1]s non può aggiornarsi nella posizione in cui è installato. Se è stato installato con un gestore di pacchetti, aggiornalo da lì.",
    developmentBuild: "Le build di sviluppo non si aggiornano da sole.",
    error: "Errore di aggiornamento!",
    checkError: "Si è verificato un errore durante la ricerca di aggiornamenti. Riprova più tardi.",
    installError: "Si è verificato un errore durante l’installazione dell’aggiornamento. Riprova più tardi.",
    available: "È disponibile una nuova versione di %[1]s!",
    availableMessage: "%[1]s %[2]s è ora disponibile (hai la versione %[3]s). Vuoi installarla adesso?",
    releaseNotes: "Note di rilascio:",
    automaticDownloads: "Scarica e installa automaticamente gli aggiornamenti in futuro",
    skip: "Salta questa versione",
    remindLater: "Ricordamelo più tardi",
    install: "Installa aggiornamento",
    downloading: "Download dell’aggiornamento…",
    progress: "%[1]s di %[2]s",
    megabytes: "%s MB",
    installing: "Installazione dell’aggiornamento…",
    ready: "Pronto per il riavvio",
    readyMessage: "%[1]s %[2]s è installato e si avvierà la prossima volta che apri %[1]s. Riavvia ora per iniziare a usarlo.",
    later: "Più tardi",
    relaunch: "Riavvia ora"
  )
  catalog["ja"] = Strings(
    title: "ソフトウェア・アップデート",
    menuItem: "アップデートを確認…",
    checking: "アップデートを確認中…",
    cancel: "キャンセル",
    ok: "OK",
    upToDate: "最新の状態です",
    upToDateMessage: "%[1]s %[2]s は現在入手できる最新バージョンです。",
    unavailable: "アップデートを利用できません",
    unavailableMessage: "%[1]s はインストールされている場所では自動でアップデートできません。パッケージマネージャでインストールした場合は、そちらでアップデートしてください。",
    developmentBuild: "開発用ビルドは自動でアップデートされません。",
    error: "アップデートエラー",
    checkError: "アップデートの確認中にエラーが起きました。後でもう一度お試しください。",
    installError: "アップデートのインストール中にエラーが起きました。後でもう一度お試しください。",
    available: "%[1]s の新しいバージョンがあります",
    availableMessage: "%[1]s %[2]s が利用可能です（現在のバージョンは %[3]s）。今すぐインストールしますか？",
    releaseNotes: "リリースノート：",
    automaticDownloads: "今後はアップデートを自動的にダウンロードしてインストール",
    skip: "このバージョンをスキップ",
    remindLater: "後で通知",
    install: "アップデートをインストール",
    downloading: "アップデートをダウンロード中…",
    progress: "%[1]s / %[2]s",
    megabytes: "%s MB",
    installing: "アップデートをインストール中…",
    ready: "再起動の準備ができました",
    readyMessage: "%[1]s %[2]s がインストールされました。次回 %[1]s を開いたときに起動します。今すぐ再起動すると使い始められます。",
    later: "後で",
    relaunch: "今すぐ再起動"
  )
  catalog["ko"] = Strings(
    title: "소프트웨어 업데이트",
    menuItem: "업데이트 확인…",
    checking: "업데이트 확인 중…",
    cancel: "취소",
    ok: "확인",
    upToDate: "최신 버전입니다!",
    upToDateMessage: "%[1]s %[2]s이(가) 현재 사용 가능한 최신 버전입니다.",
    unavailable: "업데이트를 사용할 수 없음",
    unavailableMessage: "%[1]s은(는) 설치된 위치에서 스스로 업데이트할 수 없습니다. 패키지 관리자로 설치했다면 해당 관리자에서 업데이트하십시오.",
    developmentBuild: "개발용 빌드는 스스로 업데이트하지 않습니다.",
    error: "업데이트 오류!",
    checkError: "업데이트를 확인하는 중 오류가 발생했습니다. 나중에 다시 시도하십시오.",
    installError: "업데이트를 설치하는 중 오류가 발생했습니다. 나중에 다시 시도하십시오.",
    available: "%[1]s의 새 버전을 사용할 수 있습니다!",
    availableMessage: "%[1]s %[2]s을(를) 사용할 수 있습니다(현재 버전: %[3]s). 지금 설치하시겠습니까?",
    releaseNotes: "릴리즈 노트:",
    automaticDownloads: "앞으로 업데이트를 자동으로 다운로드하고 설치",
    skip: "이 버전 건너뛰기",
    remindLater: "나중에 알림",
    install: "업데이트 설치",
    downloading: "업데이트 다운로드 중…",
    progress: "%[1]s / %[2]s",
    megabytes: "%s MB",
    installing: "업데이트 설치 중…",
    ready: "다시 실행 준비 완료",
    readyMessage: "%[1]s %[2]s이(가) 설치되었으며 다음에 %[1]s을(를) 열 때 실행됩니다. 지금 다시 실행하여 사용을 시작하십시오.",
    later: "나중에",
    relaunch: "지금 다시 실행"
  )
  catalog["nl"] = Strings(
    title: "Software-update",
    menuItem: "Zoek naar updates…",
    checking: "Zoeken naar updates…",
    cancel: "Annuleer",
    ok: "OK",
    upToDate: "Je bent up-to-date!",
    upToDateMessage: "%[1]s %[2]s is momenteel de nieuwste beschikbare versie.",
    unavailable: "Updates niet beschikbaar",
    unavailableMessage: "%[1]s kan zichzelf niet bijwerken op de plek waar het is geïnstalleerd. Als een pakketbeheerder het heeft geïnstalleerd, werk het daar bij.",
    developmentBuild: "Ontwikkelversies werken zichzelf niet bij.",
    error: "Fout bij update!",
    checkError: "Er is een fout opgetreden bij het zoeken naar updates. Probeer het later opnieuw.",
    installError: "Er is een fout opgetreden bij het installeren van de update. Probeer het later opnieuw.",
    available: "Er is een nieuwe versie van %[1]s beschikbaar!",
    availableMessage: "%[1]s %[2]s is nu beschikbaar (je hebt %[3]s). Wil je deze nu installeren?",
    releaseNotes: "Release-opmerkingen:",
    automaticDownloads: "Updates voortaan automatisch downloaden en installeren",
    skip: "Sla deze versie over",
    remindLater: "Herinner me later",
    install: "Installeer update",
    downloading: "Update downloaden…",
    progress: "%[1]s van %[2]s",
    megabytes: "%s MB",
    installing: "Update installeren…",
    ready: "Klaar om opnieuw te starten",
    readyMessage: "%[1]s %[2]s is geïnstalleerd en start de volgende keer dat je %[1]s opent. Start nu opnieuw om het te gebruiken.",
    later: "Later",
    relaunch: "Start nu opnieuw"
  )
  catalog["pl"] = Strings(
    title: "Aktualizacja oprogramowania",
    menuItem: "Sprawdź aktualizacje…",
    checking: "Sprawdzanie aktualizacji…",
    cancel: "Anuluj",
    ok: "OK",
    upToDate: "Masz najnowszą wersję!",
    upToDateMessage: "Wersja %[2]s aplikacji %[1]s jest obecnie najnowszą dostępną wersją.",
    unavailable: "Aktualizacje niedostępne",
    unavailableMessage: "Aplikacja %[1]s nie może zaktualizować się w miejscu, w którym jest zainstalowana. Jeśli zainstalował ją menedżer pakietów, zaktualizuj ją tam.",
    developmentBuild: "Wersje deweloperskie nie aktualizują się same.",
    error: "Błąd aktualizacji!",
    checkError: "Wystąpił błąd podczas sprawdzania aktualizacji. Spróbuj ponownie później.",
    installError: "Wystąpił błąd podczas instalowania aktualizacji. Spróbuj ponownie później.",
    available: "Dostępna jest nowa wersja aplikacji %[1]s!",
    availableMessage: "Wersja %[2]s aplikacji %[1]s jest już dostępna (masz wersję %[3]s). Czy chcesz ją teraz zainstalować?",
    releaseNotes: "Informacje o wersji:",
    automaticDownloads: "W przyszłości automatycznie pobieraj i instaluj aktualizacje",
    skip: "Pomiń tę wersję",
    remindLater: "Przypomnij później",
    install: "Zainstaluj aktualizację",
    downloading: "Pobieranie aktualizacji…",
    progress: "%[1]s z %[2]s",
    megabytes: "%s MB",
    installing: "Instalowanie aktualizacji…",
    ready: "Gotowe do ponownego uruchomienia",
    readyMessage: "Wersja %[2]s aplikacji %[1]s jest zainstalowana i uruchomi się przy następnym otwarciu aplikacji %[1]s. Uruchom ją ponownie teraz, aby zacząć z niej korzystać.",
    later: "Później",
    relaunch: "Uruchom ponownie"
  )
  catalog["pt-BR"] = Strings(
    title: "Atualização de Software",
    menuItem: "Verificar atualizações…",
    checking: "Verificando atualizações…",
    cancel: "Cancelar",
    ok: "OK",
    upToDate: "Você já tem a versão mais recente!",
    upToDateMessage: "%[1]s %[2]s é a versão mais recente disponível.",
    unavailable: "Atualizações indisponíveis",
    unavailableMessage: "%[1]s não pode se atualizar no local onde está instalado. Se ele foi instalado por um gerenciador de pacotes, atualize-o por lá.",
    developmentBuild: "Versões de desenvolvimento não se atualizam sozinhas.",
    error: "Erro de atualização!",
    checkError: "Ocorreu um erro ao verificar atualizações. Tente novamente mais tarde.",
    installError: "Ocorreu um erro ao instalar a atualização. Tente novamente mais tarde.",
    available: "Uma nova versão de %[1]s está disponível!",
    availableMessage: "%[1]s %[2]s já está disponível (você tem a versão %[3]s). Deseja instalá-la agora?",
    releaseNotes: "Notas da versão:",
    automaticDownloads: "Baixar e instalar atualizações automaticamente no futuro",
    skip: "Ignorar esta versão",
    remindLater: "Lembrar mais tarde",
    install: "Instalar atualização",
    downloading: "Baixando atualização…",
    progress: "%[1]s de %[2]s",
    megabytes: "%s MB",
    installing: "Instalando atualização…",
    ready: "Pronto para reabrir",
    readyMessage: "%[1]s %[2]s está instalado e será iniciado na próxima vez que você abrir %[1]s. Reabra agora para começar a usá-lo.",
    later: "Mais tarde",
    relaunch: "Reabrir agora"
  )
  catalog["ru"] = Strings(
    title: "Обновление ПО",
    menuItem: "Проверить обновления…",
    checking: "Проверка обновлений…",
    cancel: "Отмена",
    ok: "ОК",
    upToDate: "У вас последняя версия!",
    upToDateMessage: "%[1]s %[2]s — самая новая из доступных версий.",
    unavailable: "Обновления недоступны",
    unavailableMessage: "Приложение %[1]s не может обновить себя в месте установки. Если оно установлено менеджером пакетов, обновите его там.",
    developmentBuild: "Сборки для разработки не обновляются сами.",
    error: "Ошибка обновления!",
    checkError: "При проверке обновлений произошла ошибка. Повторите попытку позже.",
    installError: "При установке обновления произошла ошибка. Повторите попытку позже.",
    available: "Доступна новая версия %[1]s!",
    availableMessage: "Доступна версия %[1]s %[2]s (у вас %[3]s). Установить её сейчас?",
    releaseNotes: "Что нового:",
    automaticDownloads: "Автоматически загружать и устанавливать обновления в будущем",
    skip: "Пропустить эту версию",
    remindLater: "Напомнить позже",
    install: "Установить обновление",
    downloading: "Загрузка обновления…",
    progress: "%[1]s из %[2]s",
    megabytes: "%s МБ",
    installing: "Установка обновления…",
    ready: "Готово к перезапуску",
    readyMessage: "%[1]s %[2]s установлено и запустится при следующем открытии %[1]s. Перезапустите сейчас, чтобы начать пользоваться новой версией.",
    later: "Позже",
    relaunch: "Перезапустить"
  )
  catalog["tr"] = Strings(
    title: "Yazılım Güncelleme",
    menuItem: "Güncellemeleri Denetle…",
    checking: "Güncellemeler denetleniyor…",
    cancel: "Vazgeç",
    ok: "Tamam",
    upToDate: "En son sürümü kullanıyorsunuz!",
    upToDateMessage: "%[1]s %[2]s şu anda mevcut en yeni sürüm.",
    unavailable: "Güncellemeler Kullanılamıyor",
    unavailableMessage: "%[1]s yüklü olduğu konumda kendini güncelleyemiyor. Bir paket yöneticisiyle yüklendiyse oradan güncelleyin.",
    developmentBuild: "Geliştirme sürümleri kendilerini güncellemez.",
    error: "Güncelleme Hatası!",
    checkError: "Güncellemeler denetlenirken bir hata oluştu. Lütfen daha sonra yeniden deneyin.",
    installError: "Güncelleme yüklenirken bir hata oluştu. Lütfen daha sonra yeniden deneyin.",
    available: "%[1]s için yeni bir sürüm var!",
    availableMessage: "%[1]s %[2]s artık kullanılabilir (sizdeki sürüm %[3]s). Şimdi yüklemek ister misiniz?",
    releaseNotes: "Sürüm Notları:",
    automaticDownloads: "Gelecekte güncellemeleri otomatik olarak indir ve yükle",
    skip: "Bu Sürümü Atla",
    remindLater: "Daha Sonra Hatırlat",
    install: "Güncellemeyi Yükle",
    downloading: "Güncelleme indiriliyor…",
    progress: "%[1]s / %[2]s",
    megabytes: "%s MB",
    installing: "Güncelleme yükleniyor…",
    ready: "Yeniden Başlatmaya Hazır",
    readyMessage: "%[1]s %[2]s yüklendi ve %[1]s bir sonraki açılışında başlayacak. Kullanmaya başlamak için şimdi yeniden başlatın.",
    later: "Daha Sonra",
    relaunch: "Şimdi Yeniden Başlat"
  )
  catalog["uk"] = Strings(
    title: "Оновлення ПЗ",
    menuItem: "Перевірити оновлення…",
    checking: "Перевірка оновлень…",
    cancel: "Скасувати",
    ok: "OK",
    upToDate: "У вас остання версія!",
    upToDateMessage: "%[1]s %[2]s — найновіша доступна версія.",
    unavailable: "Оновлення недоступні",
    unavailableMessage: "Застосунок %[1]s не може оновити себе в місці встановлення. Якщо його встановив менеджер пакетів, оновіть його там.",
    developmentBuild: "Збірки для розробки не оновлюються самі.",
    error: "Помилка оновлення!",
    checkError: "Під час перевірки оновлень сталася помилка. Спробуйте пізніше.",
    installError: "Під час встановлення оновлення сталася помилка. Спробуйте пізніше.",
    available: "Доступна нова версія %[1]s!",
    availableMessage: "Доступна версія %[1]s %[2]s (у вас %[3]s). Встановити її зараз?",
    releaseNotes: "Що нового:",
    automaticDownloads: "Автоматично завантажувати та встановлювати оновлення надалі",
    skip: "Пропустити цю версію",
    remindLater: "Нагадати пізніше",
    install: "Встановити оновлення",
    downloading: "Завантаження оновлення…",
    progress: "%[1]s з %[2]s",
    megabytes: "%s МБ",
    installing: "Встановлення оновлення…",
    ready: "Готово до перезапуску",
    readyMessage: "%[1]s %[2]s встановлено, і ця версія запуститься під час наступного відкриття %[1]s. Перезапустіть зараз, щоб почати нею користуватися.",
    later: "Пізніше",
    relaunch: "Перезапустити"
  )
  catalog["zh-Hans"] = Strings(
    title: "软件更新",
    menuItem: "检查更新…",
    checking: "正在检查更新…",
    cancel: "取消",
    ok: "好",
    upToDate: "已是最新版本！",
    upToDateMessage: "%[1]s %[2]s 是目前可用的最新版本。",
    unavailable: "无法更新",
    unavailableMessage: "%[1]s 无法在当前安装位置自行更新。如果它是通过软件包管理器安装的，请在那里更新。",
    developmentBuild: "开发版本不会自行更新。",
    error: "更新出错！",
    checkError: "检查更新时出错，请稍后再试。",
    installError: "安装更新时出错，请稍后再试。",
    available: "%[1]s 有新版本可用！",
    availableMessage: "%[1]s %[2]s 现已推出，你当前的版本是 %[3]s。要现在安装吗？",
    releaseNotes: "更新说明：",
    automaticDownloads: "以后自动下载并安装更新",
    skip: "跳过这个版本",
    remindLater: "稍后提醒我",
    install: "安装更新",
    downloading: "正在下载更新…",
    progress: "%[1]s / %[2]s",
    megabytes: "%s MB",
    installing: "正在安装更新…",
    ready: "可以重新启动了",
    readyMessage: "%[1]s %[2]s 已安装，将在下次打开 %[1]s 时启动。立即重新启动即可开始使用。",
    later: "稍后",
    relaunch: "立即重新启动"
  )
  catalog["zh-Hant"] = Strings(
    title: "軟體更新",
    menuItem: "檢查更新項目…",
    checking: "正在檢查更新項目…",
    cancel: "取消",
    ok: "好",
    upToDate: "已是最新版本！",
    upToDateMessage: "%[1]s %[2]s 是目前可用的最新版本。",
    unavailable: "無法更新",
    unavailableMessage: "%[1]s 無法在目前的安裝位置自行更新。如果它是透過套件管理工具安裝的，請在那裡更新。",
    developmentBuild: "開發版本不會自行更新。",
    error: "更新發生錯誤！",
    checkError: "檢查更新項目時發生錯誤，請稍後再試。",
    installError: "安裝更新項目時發生錯誤，請稍後再試。",
    available: "%[1]s 有新版本可用！",
    availableMessage: "%[1]s %[2]s 現已推出，你目前的版本是 %[3]s。要立即安裝嗎？",
    releaseNotes: "版本說明：",
    automaticDownloads: "日後自動下載並安裝更新項目",
    skip: "略過此版本",
    remindLater: "稍後提醒我",
    install: "安裝更新項目",
    downloading: "正在下載更新項目…",
    progress: "%[1]s / %[2]s",
    megabytes: "%s MB",
    installing: "正在安裝更新項目…",
    ready: "準備重新啟動",
    readyMessage: "%[1]s %[2]s 已安裝，會在下次打開 %[1]s 時啟動。立即重新啟動即可開始使用。",
    later: "稍後",
    relaunch: "立即重新啟動"
  )
  catalog

type Text* = object
  ## Window strings resolved for the app's locale and custom overrides.
  strings*: Strings
  language*: string
  decimalComma*, rtl*: bool

proc baseLanguage(tag: string): string =
  let dash = tag.find('-')
  (if dash < 0: tag else: tag[0..<dash]).toLowerAscii()

proc hasLanguage(languages: openArray[string]; candidate: string): bool =
  for language in languages:
    if cmpIgnoreCase(language, candidate) == 0:
      return true

proc matchLanguage*(locale: string; available: openArray[string]): string =
  ## Chooses the closest available language and script for a locale tag.
  var tag = locale
  let dot = tag.find('.')
  if dot >= 0:
    tag.setLen(dot)
  let modifier = tag.find('@')
  if modifier >= 0:
    tag.setLen(modifier)
  var parts: seq[string]
  for part in tag.split({'-', '_'}):
    if part.len > 0:
      parts.add(part)
  if parts.len == 0:
    return "en"

  let language = parts[0].toLowerAscii()
  var script, region: string
  for i in 1..<parts.len:
    let part = parts[i]
    if part.len == 4:
      script = part[0].toUpperAscii() & part[1..^1].toLowerAscii()
    elif part.len == 2 or
        (part.len == 3 and part[0] in {'0'..'9'}):
      region = part.toUpperAscii()
  if language == "zh" and script.len == 0:
    script = "Hans"
    if region in ["TW", "HK", "MO"]:
      script = "Hant"

  var candidates: seq[string]
  if script.len > 0:
    candidates.add(language & "-" & script & "-" & region)
    candidates.add(language & "-" & script)
  candidates.add(language & "-" & region)
  candidates.add(language)
  for candidate in candidates:
    if available.hasLanguage(candidate):
      for found in available:
        if cmpIgnoreCase(found, candidate) == 0:
          return found

  if language != "zh":
    for found in available:
      if baseLanguage(found) == language:
        return found
  "en"

proc merge(target: var Strings; fallback: Strings) =
  if target.title.len == 0: target.title = fallback.title
  if target.menuItem.len == 0: target.menuItem = fallback.menuItem
  if target.checking.len == 0: target.checking = fallback.checking
  if target.cancel.len == 0: target.cancel = fallback.cancel
  if target.ok.len == 0: target.ok = fallback.ok
  if target.upToDate.len == 0: target.upToDate = fallback.upToDate
  if target.upToDateMessage.len == 0:
    target.upToDateMessage = fallback.upToDateMessage
  if target.unavailable.len == 0: target.unavailable = fallback.unavailable
  if target.unavailableMessage.len == 0:
    target.unavailableMessage = fallback.unavailableMessage
  if target.developmentBuild.len == 0:
    target.developmentBuild = fallback.developmentBuild
  if target.error.len == 0: target.error = fallback.error
  if target.checkError.len == 0: target.checkError = fallback.checkError
  if target.installError.len == 0: target.installError = fallback.installError
  if target.available.len == 0: target.available = fallback.available
  if target.availableMessage.len == 0:
    target.availableMessage = fallback.availableMessage
  if target.releaseNotes.len == 0: target.releaseNotes = fallback.releaseNotes
  if target.automaticDownloads.len == 0:
    target.automaticDownloads = fallback.automaticDownloads
  if target.skip.len == 0: target.skip = fallback.skip
  if target.remindLater.len == 0: target.remindLater = fallback.remindLater
  if target.install.len == 0: target.install = fallback.install
  if target.downloading.len == 0: target.downloading = fallback.downloading
  if target.progress.len == 0: target.progress = fallback.progress
  if target.megabytes.len == 0: target.megabytes = fallback.megabytes
  if target.installing.len == 0: target.installing = fallback.installing
  if target.ready.len == 0: target.ready = fallback.ready
  if target.readyMessage.len == 0: target.readyMessage = fallback.readyMessage
  if target.later.len == 0: target.later = fallback.later
  if target.relaunch.len == 0: target.relaunch = fallback.relaunch

proc newText*(locale: string; extra: Table[string, Strings]): Text =
  ## Resolves a locale, then fills custom and localized strings from English.
  var available: seq[string]
  for language in translations.keys:
    available.add(language)
  for language in extra.keys:
    available.add(language)
  available.sort()

  result.language = matchLanguage(locale, available)
  for language, strings in extra:
    if cmpIgnoreCase(language, result.language) == 0:
      result.strings = strings
      break
  for language, strings in translations:
    if cmpIgnoreCase(language, result.language) == 0:
      result.strings.merge(strings)
      break
  result.strings.merge(english)

  let normalized = result.language.toLowerAscii()
  result.decimalComma = normalized in [
    "de", "es", "fr", "it", "nl", "pl", "pt-br", "ru", "tr", "uk"
  ]
  result.rtl = baseLanguage(result.language) in ["ar", "fa", "he", "ps", "ur", "yi"]

proc frontendTexts*(text: Text): frontend.Texts =
  ## Returns the strings used by the native window outside its views.
  frontend.Texts(title: text.strings.title,
    releaseNotes: text.strings.releaseNotes,
    automaticDownloads: text.strings.automaticDownloads,
    lang: text.language, rtl: text.rtl)

proc formatStrings*(pattern: string; args: openArray[string]): string =
  ## Fills MyGo's indexed `%s` placeholders, such as `%[2]s`.
  var i, nextArg = 0
  while i < pattern.len:
    if pattern[i] != '%':
      result.add(pattern[i])
      inc i
      continue
    if i + 1 < pattern.len and pattern[i + 1] == '%':
      result.add('%')
      i += 2
      continue
    inc i
    var index = nextArg
    if i < pattern.len and pattern[i] == '[':
      inc i
      let start = i
      while i < pattern.len and pattern[i] in {'0'..'9'}:
        inc i
      if start == i or i >= pattern.len or pattern[i] != ']':
        raise newException(ValueError, "updater: invalid string format")
      try:
        index = parseInt(pattern[start..<i]) - 1
      except ValueError:
        raise newException(ValueError, "updater: invalid string format")
      inc i
    else:
      inc nextArg
    if i >= pattern.len or pattern[i] != 's' or index < 0 or index >= args.len:
      raise newException(ValueError, "updater: invalid string format")
    result.add(args[index])
    nextArg = max(nextArg, index + 1)
    inc i

proc validFormat(pattern: string; argumentCount: int): bool =
  var used = newSeq[bool](argumentCount)
  var i, nextArg = 0
  while i < pattern.len:
    if pattern[i] != '%':
      inc i
      continue
    inc i
    if i < pattern.len and pattern[i] == '%':
      inc i
      continue
    var index = nextArg
    if i < pattern.len and pattern[i] == '[':
      inc i
      let start = i
      while i < pattern.len and pattern[i] in {'0'..'9'}:
        inc i
      if start == i or i >= pattern.len or pattern[i] != ']':
        return false
      try:
        index = parseInt(pattern[start..<i]) - 1
      except ValueError:
        return false
      inc i
    else:
      inc nextArg
    if i >= pattern.len or pattern[i] != 's' or index < 0 or
        index >= argumentCount:
      return false
    used[index] = true
    nextArg = max(nextArg, index + 1)
    inc i
  for wasUsed in used:
    if not wasUsed:
      return false
  true

proc checkStrings*(strings: Strings): string =
  ## Reports the first malformed formatted field in a string override.
  let formats = [
    ("UpToDateMessage", strings.upToDateMessage, 2),
    ("UnavailableMessage", strings.unavailableMessage, 1),
    ("Available", strings.available, 1),
    ("AvailableMessage", strings.availableMessage, 3),
    ("Progress", strings.progress, 2),
    ("Megabytes", strings.megabytes, 1),
    ("ReadyMessage", strings.readyMessage, 2)
  ]
  for (name, pattern, count) in formats:
    if pattern.len > 0 and not validFormat(pattern, count):
      return name & " " & pattern.escape() & " is not a format of " &
        $count & " strings"

proc validateStrings*(extra: Table[string, Strings]): string =
  ## Validates the formatted fields in custom locale strings.
  for language, strings in extra:
    let problem = checkStrings(strings)
    if problem.len > 0:
      if result.len > 0:
        result.add('\n')
      result.add("strings of " & language.escape() & ": " & problem)

proc megabytes*(text: Text; bytes: int64): string =
  ## Formats a decimal megabyte size with the locale's decimal mark.
  var number = formatFloat(float64(bytes) / 1_000_000, ffDecimal, 1)
  if text.decimalComma:
    number = number.replace('.', ',')
  formatStrings(text.strings.megabytes, [number])

proc okButtons*(text: Text): seq[frontend.Button] =
  @[frontend.Button(action: frontend.Ok, label: text.strings.ok,
    default: true, cancel: true)]

proc cancelButtons*(text: Text; disabled: bool): seq[frontend.Button] =
  @[frontend.Button(action: frontend.Cancel, label: text.strings.cancel,
    cancel: true, disabled: disabled)]

proc checkingView*(text: Text): frontend.View =
  frontend.View(title: text.strings.checking, bar: true, progress: -1,
    buttons: text.cancelButtons(false))

proc upToDateView*(text: Text; appName, version: string): frontend.View =
  frontend.View(title: text.strings.upToDate,
    message: formatStrings(text.strings.upToDateMessage, [appName, version]),
    buttons: text.okButtons())

proc unavailableView*(text: Text; appName: string;
                      developmentBuild: bool): frontend.View =
  let message = if developmentBuild:
      text.strings.developmentBuild
    else:
      formatStrings(text.strings.unavailableMessage, [appName])
  frontend.View(title: text.strings.unavailable, message: message,
    buttons: text.okButtons())

proc errorView*(text: Text; message: string;
                error: ref CatchableError): frontend.View =
  frontend.View(title: text.strings.error, message: message,
    detail: if error == nil: "" else: error.msg,
    buttons: text.okButtons())

proc availableView*(text: Text; appName, version, currentVersion,
                    releaseNotes: string;
                    automaticDownloads: bool): frontend.View =
  let notes = markdown.parse(releaseNotes)
  frontend.View(release: notes.len > 0,
    title: formatStrings(text.strings.available, [appName]),
    message: formatStrings(text.strings.availableMessage,
      [appName, version, currentVersion]),
    notes: notes, checkbox: true, checked: automaticDownloads,
    buttons: @[
      frontend.Button(action: frontend.Skip, label: text.strings.skip,
        aside: true),
      frontend.Button(action: frontend.Later, label: text.strings.remindLater,
        cancel: true),
      frontend.Button(action: frontend.Install, label: text.strings.install,
        default: true)
    ])

proc downloadingView*(text: Text; downloaded, total: int64): frontend.View =
  result = frontend.View(title: text.strings.downloading, bar: true,
    progress: -1, buttons: text.cancelButtons(false))
  if total > 0:
    result.progress = float64(downloaded) / float64(total)
    result.message = formatStrings(text.strings.progress,
      [text.megabytes(downloaded), text.megabytes(total)])

proc installingView*(text: Text): frontend.View =
  frontend.View(title: text.strings.installing, bar: true, progress: -1,
    buttons: text.cancelButtons(true))

proc readyView*(text: Text; appName, version: string): frontend.View =
  frontend.View(title: text.strings.ready,
    message: formatStrings(text.strings.readyMessage, [appName, version]),
    buttons: @[
      frontend.Button(action: frontend.Later, label: text.strings.later,
        cancel: true),
      frontend.Button(action: frontend.Relaunch, label: text.strings.relaunch,
        default: true)
    ])
