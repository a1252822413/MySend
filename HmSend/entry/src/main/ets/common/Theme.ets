// 设计令牌：与 design/ui-redesign/styles/tokens.css 一一对应。
// 两套主题不是反色关系——亮色把绿色压深（图形 accent / 文字 accentInk 分开），
// 暗色靠背景色差 + 内侧高光分层，亮色靠投影，所以字段拆得比较细。
//
// 用法：
//   @StorageLink('themeMode') themeMode: string = 'dark';
//   private get tk(): ThemeTokens { return tokensOf(this.themeMode); }
// 切换主题只需 setTheme('light')，所有读 this.tk 的组件会跟着刷新。

export class ThemeTokens {
  // 表面
  bgVoid: string = '#070A09';
  bg: string = '#0A0E0C';
  surface: string = '#151F1B';
  surface2: string = '#1B2622';
  surface3: string = '#24302B';
  surfaceHi: string = '#1D2823';

  // 线
  line: string = 'rgba(233, 241, 238, 0.07)';
  lineStrong: string = 'rgba(233, 241, 238, 0.13)';
  lineAccent: string = 'rgba(59, 228, 154, 0.34)';

  // 文字
  text: string = '#E9F1EE';
  textDim: string = '#9AA8A3';
  textMute: string = '#7B8A84';

  // 强调
  accent: string = '#3BE49A';
  accentInk: string = '#3BE49A';
  onAccent: string = '#04110B';
  accentSoft: string = 'rgba(59, 228, 154, 0.13)';
  accentGlow: string = 'rgba(59, 228, 154, 0.28)';

  // 语义
  warn: string = '#FFB64D';
  danger: string = '#FF6B5A';

  // 卡片
  cardBorder: string = 'rgba(233, 241, 238, 0.10)';
  cardShadow: string = 'rgba(0, 0, 0, 0.28)';

  // 装饰
  ring: string = 'rgba(59, 228, 154, 0.55)';
  scrim: string = 'rgba(4, 7, 6, 0.62)';
  scrimSoft: string = 'rgba(4, 7, 6, 0.38)';
  grid: string = 'rgba(233, 241, 238, 0.03)';
}

function createDark(): ThemeTokens {
  const t = new ThemeTokens();
  t.bgVoid = '#070A09';
  t.bg = '#0A0E0C';
  t.surface = '#151F1B';
  t.surface2 = '#1B2622';
  t.surface3 = '#24302B';
  t.surfaceHi = '#1D2823';

  t.line = 'rgba(233, 241, 238, 0.07)';
  t.lineStrong = 'rgba(233, 241, 238, 0.13)';
  t.lineAccent = 'rgba(59, 228, 154, 0.34)';

  t.text = '#E9F1EE';
  t.textDim = '#9AA8A3';
  t.textMute = '#7B8A84';

  t.accent = '#3BE49A';
  t.accentInk = '#3BE49A';
  t.onAccent = '#04110B';
  t.accentSoft = 'rgba(59, 228, 154, 0.13)';
  t.accentGlow = 'rgba(59, 228, 154, 0.28)';

  t.warn = '#FFB64D';
  t.danger = '#FF6B5A';

  t.cardBorder = 'rgba(233, 241, 238, 0.10)';
  t.cardShadow = 'rgba(0, 0, 0, 0.28)';

  t.ring = 'rgba(59, 228, 154, 0.55)';
  t.scrim = 'rgba(4, 7, 6, 0.62)';
  t.scrimSoft = 'rgba(4, 7, 6, 0.38)';
  t.grid = 'rgba(233, 241, 238, 0.03)';
  return t;
}

function createLight(): ThemeTokens {
  const t = new ThemeTokens();
  t.bgVoid = '#EAEEEC';
  t.bg = '#F0F3F1';
  t.surface = '#FFFFFF';
  t.surface2 = '#F1F5F3';
  t.surface3 = '#E3EAE7';
  t.surfaceHi = '#FBFDFC';

  t.line = 'rgba(16, 22, 19, 0.07)';
  t.lineStrong = 'rgba(16, 22, 19, 0.13)';
  t.lineAccent = 'rgba(11, 143, 91, 0.3)';

  t.text = '#0F1614';
  t.textDim = '#55635C';
  t.textMute = '#6B7A72';

  // 亮底上绿色必须压深：图形用 accent，小字用 accentInk
  t.accent = '#0A8255';
  t.accentInk = '#07714A';
  t.onAccent = '#FFFFFF';
  t.accentSoft = 'rgba(11, 143, 91, 0.1)';
  t.accentGlow = 'rgba(11, 143, 91, 0.22)';

  t.warn = '#B06F00';
  t.danger = '#C0392B';

  t.cardBorder = 'rgba(16, 22, 19, 0.07)';
  t.cardShadow = 'rgba(16, 22, 19, 0.10)';

  t.ring = 'rgba(10, 130, 85, 0.48)';
  t.scrim = 'rgba(15, 22, 19, 0.3)';
  t.scrimSoft = 'rgba(15, 22, 19, 0.22)';
  t.grid = 'rgba(16, 22, 19, 0.045)';
  return t;
}

const DARK: ThemeTokens = createDark();
const LIGHT: ThemeTokens = createLight();

/** 按模式取令牌；未知值一律按暗色处理 */
export function tokensOf(mode: string): ThemeTokens {
  return mode === 'light' ? LIGHT : DARK;
}

/** 当前是否暗色（给需要二值判断的地方用，比如阴影强度） */
export function isDark(mode: string): boolean {
  return mode !== 'light';
}

/** 应用启动时把持久化的模式灌进 AppStorage */
export function initTheme(mode: string): void {
  AppStorage.setOrCreate<string>('themeMode', mode === 'light' ? 'light' : 'dark');
}

/** 切换主题（全局生效，页面通过 @StorageLink 自动刷新） */
export function setTheme(mode: string): void {
  AppStorage.setOrCreate<string>('themeMode', mode === 'light' ? 'light' : 'dark');
}
