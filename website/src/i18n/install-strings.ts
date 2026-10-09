// Copy for the "How to install" section, per site language.
import type { Lang } from "./strings";

export type Platform = "mac" | "ios" | "tv";

export interface Step {
  t: string;
  b: string;
}

export interface InstallCopy {
  nav: string;
  l1: string;
  l2: string;
  sub: string;
  device: Record<Platform, string>;
  req: Record<Platform, string>;
  tag: Record<Platform, string>;
  dl: Record<Platform, string>;
  sideloadly: string;
  steps: Record<Platform, Step[]>;
  keep: { t: string; b: string; free: string; freeTime: string; paid: string; paidTime: string; tip: string };
  guide: string;
  cta: string;
}

export const INSTALL: Record<Lang, InstallCopy> = {
  en: {
    nav: "Install",
    l1: "Get Yingxia",
    l2: "on every screen.",
    sub: "The Mac app is a signed download. The iPhone, iPad and Apple TV apps are in preview: install them with Sideloadly and your own Apple account, free or paid.",
    device: { mac: "Mac", ios: "iPhone & iPad", tv: "Apple TV" },
    req: { mac: "macOS 26+ · Apple silicon", ios: "iOS & iPadOS 26+", tv: "tvOS 26+" },
    tag: { mac: "Signed & notarized", ios: "Preview · Sideload", tv: "Preview · Sideload" },
    dl: { mac: "Download for Mac", ios: "Download the iPhone & iPad IPA", tv: "Download the Apple TV IPA" },
    sideloadly: "Get Sideloadly",
    steps: {
      mac: [
        { t: "Download", b: "Get the disk image. It's signed and notarized by Apple." },
        { t: "Drag to Applications", b: "Open the DMG and drag Yingxia into your Applications folder." },
        { t: "Open and subscribe", b: "Launch Yingxia and paste your TVBox subscription URL." },
      ],
      ios: [
        { t: "Download two things", b: "The Yingxia IPA for iPhone and iPad, and Sideloadly for Mac or Windows." },
        { t: "Plug in and trust", b: "Connect with a USB cable, unlock the device, and tap Trust." },
        { t: "Drop and start", b: "Drag the IPA into Sideloadly, enter your Apple account email, and click Start." },
        { t: "Trust the developer", b: "On the device, open Settings → General → VPN & Device Management and trust your Apple account. Turn on Developer Mode if asked." },
        { t: "Press play", b: "Open Yingxia and add your subscription." },
      ],
      tv: [
        { t: "Use a Mac", b: "Download the Apple TV IPA and Sideloadly for Mac. Apple TV 4K installs over the network, which Sideloadly supports only on Mac." },
        { t: "Same network", b: "Put your Mac and Apple TV on the same local network." },
        { t: "Open pairing", b: "On Apple TV, go to Settings → Remotes and Devices → Remote App and Devices, and leave that screen open." },
        { t: "Pair, drop and start", b: "Select the Apple TV in Sideloadly and pair, drag in the IPA, enter your Apple account email, and click Start." },
        { t: "Press play", b: "Open Yingxia on your Apple TV." },
      ],
    },
    keep: {
      t: "Keep it signed",
      b: "Sideloaded apps stop opening when their signature expires. Turn on automatic refresh in Sideloadly to renew it in the background while your computer is on.",
      free: "Free Apple account",
      freeTime: "7 days",
      paid: "Apple Developer Program",
      paidTime: "1 year",
      tip: "Reinstall with the same Apple account to keep your favorites and history.",
    },
    guide: "Full guide and troubleshooting",
    cta: "Install on iPhone, iPad & Apple TV",
  },
  ja: {
    nav: "インストール",
    l1: "どの画面にも、",
    l2: "映匣を。",
    sub: "Mac 版は署名済みアプリとしてダウンロードできます。iPhone、iPad、Apple TV 版はプレビューとして、Sideloadly とご自身の Apple アカウント（無料・有料どちらでも可）でインストールします。",
    device: { mac: "Mac", ios: "iPhone・iPad", tv: "Apple TV" },
    req: { mac: "macOS 26 以降 · Apple シリコン", ios: "iOS・iPadOS 26 以降", tv: "tvOS 26 以降" },
    tag: { mac: "署名・公証済み", ios: "プレビュー · サイドロード", tv: "プレビュー · サイドロード" },
    dl: { mac: "Mac 版をダウンロード", ios: "iPhone・iPad 用 IPA をダウンロード", tv: "Apple TV 用 IPA をダウンロード" },
    sideloadly: "Sideloadly を入手",
    steps: {
      mac: [
        { t: "ダウンロード", b: "Apple による署名・公証済みのディスクイメージを入手します。" },
        { t: "アプリケーションへ", b: "DMG を開き、映匣を「アプリケーション」フォルダにドラッグします。" },
        { t: "開いて登録", b: "映匣を起動し、TVBox のサブスクリプション URL を貼り付けます。" },
      ],
      ios: [
        { t: "2 つをダウンロード", b: "iPhone・iPad 用の映匣 IPA と、Mac または Windows 用の Sideloadly。" },
        { t: "接続して信頼", b: "USB ケーブルで接続し、デバイスのロックを解除して「信頼」をタップします。" },
        { t: "ドロップして開始", b: "IPA を Sideloadly にドラッグし、Apple アカウントのメールアドレスを入力して「Start」をクリックします。" },
        { t: "デベロッパを信頼", b: "デバイスの「設定」→「一般」→「VPN とデバイス管理」で自分の Apple アカウントを信頼します。求められたらデベロッパモードをオンにします。" },
        { t: "再生しよう", b: "映匣を開いてサブスクリプションを追加します。" },
      ],
      tv: [
        { t: "Mac を使う", b: "Apple TV 用 IPA と Mac 版 Sideloadly をダウンロードします。Apple TV 4K へはネットワーク経由でインストールし、Sideloadly では Mac のみが対応しています。" },
        { t: "同じネットワークに", b: "Mac と Apple TV を同じローカルネットワークに接続します。" },
        { t: "ペアリング画面を開く", b: "Apple TV で「設定」→「リモコンとデバイス」→「Remote App とデバイス」を開き、その画面のままにします。" },
        { t: "ペアリングして開始", b: "Sideloadly で Apple TV を選んでペアリングし、IPA をドラッグ、Apple アカウントのメールアドレスを入力して「Start」をクリックします。" },
        { t: "再生しよう", b: "Apple TV で映匣を開きます。" },
      ],
    },
    keep: {
      t: "署名を保つ",
      b: "サイドロードしたアプリは署名の期限が切れると起動しなくなります。Sideloadly の自動更新をオンにすると、コンピュータが起動している間にバックグラウンドで更新されます。",
      free: "無料の Apple アカウント",
      freeTime: "7 日間",
      paid: "Apple Developer Program",
      paidTime: "1 年間",
      tip: "同じ Apple アカウントで再インストールすれば、お気に入りや履歴はそのまま残ります。",
    },
    guide: "詳しい手順とトラブルシューティング",
    cta: "iPhone・iPad・Apple TV にインストール",
  },
  ko: {
    nav: "설치",
    l1: "모든 화면에",
    l2: "Yingxia를.",
    sub: "Mac 버전은 서명된 앱으로 바로 다운로드할 수 있습니다. iPhone, iPad, Apple TV 버전은 프리뷰로, Sideloadly와 본인의 Apple 계정(무료 또는 유료)으로 설치합니다.",
    device: { mac: "Mac", ios: "iPhone·iPad", tv: "Apple TV" },
    req: { mac: "macOS 26 이상 · Apple 실리콘", ios: "iOS·iPadOS 26 이상", tv: "tvOS 26 이상" },
    tag: { mac: "서명 및 공증 완료", ios: "프리뷰 · 사이드로드", tv: "프리뷰 · 사이드로드" },
    dl: { mac: "Mac용 다운로드", ios: "iPhone·iPad용 IPA 다운로드", tv: "Apple TV용 IPA 다운로드" },
    sideloadly: "Sideloadly 받기",
    steps: {
      mac: [
        { t: "다운로드", b: "Apple의 서명과 공증을 받은 디스크 이미지를 받습니다." },
        { t: "응용 프로그램으로", b: "DMG를 열고 Yingxia를 응용 프로그램 폴더로 드래그합니다." },
        { t: "열고 구독 추가", b: "Yingxia를 실행하고 TVBox 구독 URL을 붙여 넣습니다." },
      ],
      ios: [
        { t: "두 가지 다운로드", b: "iPhone·iPad용 Yingxia IPA와 Mac 또는 Windows용 Sideloadly." },
        { t: "연결하고 신뢰", b: "USB 케이블로 연결하고 기기 잠금을 해제한 뒤 '신뢰'를 탭합니다." },
        { t: "끌어다 놓고 시작", b: "IPA를 Sideloadly로 드래그하고 Apple 계정 이메일을 입력한 뒤 Start를 클릭합니다." },
        { t: "개발자 신뢰", b: "기기에서 설정 → 일반 → VPN 및 기기 관리로 이동해 본인의 Apple 계정을 신뢰합니다. 요청하면 개발자 모드를 켭니다." },
        { t: "재생 시작", b: "Yingxia를 열고 구독을 추가합니다." },
      ],
      tv: [
        { t: "Mac 사용", b: "Apple TV용 IPA와 Mac용 Sideloadly를 다운로드합니다. Apple TV 4K는 네트워크로 설치하며, Sideloadly는 이를 Mac에서만 지원합니다." },
        { t: "같은 네트워크", b: "Mac과 Apple TV를 같은 로컬 네트워크에 연결합니다." },
        { t: "페어링 화면 열기", b: "Apple TV에서 설정 → 리모컨 및 기기 → 리모트 앱 및 기기로 이동해 그 화면을 열어 둡니다." },
        { t: "페어링하고 시작", b: "Sideloadly에서 Apple TV를 선택해 페어링하고, IPA를 드래그한 뒤 Apple 계정 이메일을 입력하고 Start를 클릭합니다." },
        { t: "재생 시작", b: "Apple TV에서 Yingxia를 엽니다." },
      ],
    },
    keep: {
      t: "서명 유지",
      b: "사이드로드한 앱은 서명이 만료되면 열리지 않습니다. Sideloadly의 자동 갱신을 켜 두면 컴퓨터가 켜져 있는 동안 백그라운드에서 갱신됩니다.",
      free: "무료 Apple 계정",
      freeTime: "7일",
      paid: "Apple Developer Program",
      paidTime: "1년",
      tip: "같은 Apple 계정으로 다시 설치하면 즐겨찾기와 기록이 그대로 유지됩니다.",
    },
    guide: "전체 가이드 및 문제 해결",
    cta: "iPhone·iPad·Apple TV에 설치",
  },
  "zh-Hant": {
    nav: "安裝",
    l1: "每一塊螢幕，",
    l2: "都有映匣。",
    sub: "Mac 版提供已簽署的下載檔。iPhone、iPad 與 Apple TV 版以預覽形式提供，透過 Sideloadly 用你自己的 Apple 帳號（免費或付費皆可）安裝。",
    device: { mac: "Mac", ios: "iPhone 與 iPad", tv: "Apple TV" },
    req: { mac: "macOS 26 以上 · Apple 晶片", ios: "iOS 與 iPadOS 26 以上", tv: "tvOS 26 以上" },
    tag: { mac: "已簽署並公證", ios: "預覽 · 側載", tv: "預覽 · 側載" },
    dl: { mac: "下載 Mac 版", ios: "下載 iPhone 與 iPad 版 IPA", tv: "下載 Apple TV 版 IPA" },
    sideloadly: "取得 Sideloadly",
    steps: {
      mac: [
        { t: "下載", b: "取得經 Apple 簽署與公證的磁碟映像檔。" },
        { t: "拖進應用程式", b: "打開 DMG，把映匣拖到「應用程式」檔案夾。" },
        { t: "打開並加入訂閱", b: "啟動映匣，貼上你的 TVBox 訂閱網址。" },
      ],
      ios: [
        { t: "下載兩樣東西", b: "iPhone 與 iPad 版的映匣 IPA，以及 Mac 或 Windows 版的 Sideloadly。" },
        { t: "連接並信任", b: "用 USB 線連接裝置，解鎖後點一下「信任」。" },
        { t: "拖放並開始", b: "把 IPA 拖進 Sideloadly，輸入 Apple 帳號電子郵件，然後按 Start。" },
        { t: "信任開發者", b: "在裝置上前往「設定」→「一般」→「VPN 與裝置管理」，信任你的 Apple 帳號。若有提示，請開啟「開發者模式」。" },
        { t: "開始播放", b: "打開映匣，加入你的訂閱。" },
      ],
      tv: [
        { t: "使用 Mac", b: "下載 Apple TV 版 IPA 與 Mac 版 Sideloadly。Apple TV 4K 需透過網路安裝，Sideloadly 只在 Mac 上支援。" },
        { t: "同一個網路", b: "讓 Mac 與 Apple TV 連上同一個區域網路。" },
        { t: "開啟配對畫面", b: "在 Apple TV 前往「設定」→「遙控器與裝置」→「Remote App 與裝置」，並停留在該畫面。" },
        { t: "配對並開始", b: "在 Sideloadly 選擇 Apple TV 並完成配對，拖入 IPA，輸入 Apple 帳號電子郵件，然後按 Start。" },
        { t: "開始播放", b: "在 Apple TV 上打開映匣。" },
      ],
    },
    keep: {
      t: "保持簽署有效",
      b: "側載的 App 在簽署到期後就無法開啟。在 Sideloadly 開啟自動更新，電腦開著時就會在背景續簽。",
      free: "免費 Apple 帳號",
      freeTime: "7 天",
      paid: "Apple Developer Program",
      paidTime: "1 年",
      tip: "用同一個 Apple 帳號重新安裝，收藏與紀錄都會保留。",
    },
    guide: "完整指南與疑難排解",
    cta: "安裝到 iPhone、iPad 與 Apple TV",
  },
};
