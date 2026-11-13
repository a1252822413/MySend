// 快传 · HarmonyOS 统一设计令牌（交付提案，未合并进工程）
// 与 design/unified/tokens.css / tokens.json 一一对应。
// 用法：替换 HmSend/entry/src/main/ets/common/Theme.ets。
// 兼容：保留原有 ThemeTokens 全部字段与 tokensOf/isDark/initTheme/setTheme 签名，
//       现有 Index.ets 的 tk() 读取不会因替换而报错；另新增统一尺寸常量供逐步收敛。
// 注意：本文件为设计交付，尚未经过 hvigor 编译验证。

/** 间距刻度：只允许 0/4/8/12/16/24/32/48（docs/UI-SPACING.md） */
export class Spacing {
  static readonly S0: number = 0;
  static readonly S1: number = 4;
  static readonly S2: number = 8;
  static readonly S3: number = 12;
  static readonly S4: number = 16;
  static readonly S5: number = 24;
  static readonly S6: number = 32;
  static readonly S7: number = 48;
  /** 语义令牌 */
  static readonly Page: number = 24;
  static readonly Section: number = 16;
  static readonly Block: number = 12;
  static readonly Card: number = 16;
  static readonly CardCompact: number = 12;
  static readonly Control: number = 8;
  static readonly Micro: number = 4;
}

export class Radius {
  static readonly Xs: number = 4;
  static readonly Control: number = 8;
  static readonly Row: number = 10;
  static readonly Card: number = 12;
  static readonly Pill: number = 999;
}

/** 字阶：22/15/13/12/11（docs/harmonyos-app-design.md:236） */
export class FontSize {
  static readonly Display: number = 30;
  static readonly H1: number = 22;
  static readonly H2: number = 15;
  static readonly Body: number = 13;
  static readonly Sm: number = 12;
  static readonly Label: number = 11;
}

export class Size {
  static readonly ControlH: number = 36;
  static readonly TouchMin: number = 44;
  static readonly IconBlock: number = 40;
  static readonly Avatar: number = 56;
}

export class Motion {
  static readonly Fast: number = 160;
  static readonly Base: number = 300;
}

/** 系统材质适配：PC 对应 MicaBackdrop / DesktopAcrylicBackdrop / 纯色；
 *  鸿蒙对应 backgroundBlurStyle(BlurStyle.COMPONENT_THICK / COMPONENT_REGULAR / 不设)。
 *  档位由系统与省电、高对比度、减少透明状态决定，**产品内不提供材质设置项**。 */
export class Material {
  static readonly Mica: string = 'mica';
  static readonly Acrylic: string = 'acrylic';
  static readonly Solid: string = 'solid';
  /** 与 tokens.css 的 --blur-* 对齐，单位 vp */
  static readonly BlurWindowMica: number = 48;
  static readonly BlurWindowAcrylic: number = 24;
  static readonly BlurCard: number = 12;
}

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

  // 强调：图形 / 实心按钮底 / 文字（三级绿，保证 WCAG AA）
  accent: string = '#3BE49A';
  accentFill: string = '#3BE49A';
  accentInk: string = '#3BE49A';
  onAccent: string = '#04110B';
  accentSoft: string = 'rgba(59, 228, 154, 0.13)';
  accentGlow: string = 'rgba(59, 228, 154, 0.28)';

  // 语义
  success: string = '#3BE49A';
  warn: string = '#FFB64D';
  danger: string = '#FF6B5A';
  dangerSoft: string = 'rgba(255, 107, 90, 0.14)';
  onDanger: string = '#04110B';
  focus: string = '#3BE49A';

  // 卡片与氛围
  cardBorder: string = 'rgba(233, 241, 238, 0.10)';
  cardShadow: string = 'rgba(0, 0, 0, 0.20)';
  cardShadowHover: string = 'rgba(0, 0, 0, 0.26)';
  ring: string = 'rgba(59, 228, 154, 0.55)';
  scrim: string = 'rgba(4, 7, 6, 0.62)';
  scrimSoft: string = 'rgba(4, 7, 6, 0.38)';
  grid: string = 'rgba(233, 241, 238, 0.03)';

  // 材质（云母档默认值；acrylic / solid 由 Material 档位切换时覆盖）
  materialWindow: string = 'rgba(10, 14, 12, 0.72)';
  materialPanel: string = 'rgba(21, 31, 27, 0.58)';
  materialCard: string = 'rgba(21, 31, 27, 0.90)';
  blurWindow: number = 48;
  blurCard: number = 12;
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
  t.accentFill = '#3BE49A';
  t.accentInk = '#3BE49A';
  t.onAccent = '#04110B';
  t.accentSoft = 'rgba(59, 228, 154, 0.13)';
  t.accentGlow = 'rgba(59, 228, 154, 0.28)';
  t.success = '#3BE49A';
  t.warn = '#FFB64D';
  t.danger = '#FF6B5A';
  t.dangerSoft = 'rgba(255, 107, 90, 0.14)';
  t.onDanger = '#04110B';
  t.focus = '#3BE49A';
  t.cardBorder = 'rgba(233, 241, 238, 0.10)';
  t.cardShadow = 'rgba(0, 0, 0, 0.20)';
  t.cardShadowHover = 'rgba(0, 0, 0, 0.26)';
  t.ring = 'rgba(59, 228, 154, 0.55)';
  t.scrim = 'rgba(4, 7, 6, 0.62)';
  t.scrimSoft = 'rgba(4, 7, 6, 0.38)';
  t.grid = 'rgba(233, 241, 238, 0.03)';
  t.materialWindow = 'rgba(10, 14, 12, 0.72)';
  t.materialPanel = 'rgba(21, 31, 27, 0.58)';
  t.materialCard = 'rgba(21, 31, 27, 0.90)';
  t.blurWindow = 48;
  t.blurCard = 12;
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
  t.lineAccent = 'rgba(22, 163, 74, 0.30)';
  t.text = '#0F1614';
  t.textDim = '#55635C';
  t.textMute = '#6B7A72';
  // 亮色把绿压深：图形保留品牌 #16A34A，按钮底与文字再各深一档
  t.accent = '#16A34A';
  t.accentFill = '#15803D';
  t.accentInk = '#0F7A3C';
  t.onAccent = '#FFFFFF';
  t.accentSoft = 'rgba(22, 163, 74, 0.10)';
  t.accentGlow = 'rgba(22, 163, 74, 0.22)';
  t.success = '#15803D';
  t.warn = '#B06F00';
  t.danger = '#C0392B';
  t.dangerSoft = 'rgba(192, 57, 43, 0.10)';
  t.onDanger = '#FFFFFF';
  t.focus = '#0F7A3C';
  t.cardBorder = 'rgba(16, 22, 19, 0.10)';
  t.cardShadow = 'rgba(16, 22, 19, 0.06)';
  t.cardShadowHover = 'rgba(16, 22, 19, 0.10)';
  t.ring = 'rgba(22, 163, 74, 0.48)';
  t.scrim = 'rgba(15, 22, 19, 0.30)';
  t.scrimSoft = 'rgba(15, 22, 19, 0.22)';
  t.grid = 'rgba(16, 22, 19, 0.045)';
  t.materialWindow = 'rgba(246, 249, 247, 0.74)';
  t.materialPanel = 'rgba(248, 251, 249, 0.62)';
  t.materialCard = 'rgba(255, 255, 255, 0.90)';
  t.blurWindow = 48;
  t.blurCard = 12;
  return t;
}

const DARK: ThemeTokens = createDark();
const LIGHT: ThemeTokens = createLight();

/** 按模式取令牌；未知值一律按暗色处理 */
export function tokensOf(mode: string): ThemeTokens {
  return mode === 'light' ? LIGHT : DARK;
}

/** 当前是否暗色 */
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

/** v1.3 文件进度四态：与 PC ContentDialog 同名同状态，不要另造语义 */
export class FileProgressState {
  static readonly Done: string = 'done';
  static readonly Active: string = 'active';
  static readonly Wait: string = 'wait';
  static readonly Fail: string = 'fail';
}

/** 进度清单规格：列表独立滚动，总进度区与底部操作保持固定；
 *  总进度按字节加权，逐文件用各自 percent，两者不要共用一个值。 */
export class ProgressSpec {
  static readonly ListMaxHeight: number = 240;
  static readonly FileTrackHeight: number = 4;
  static readonly SummaryTrackHeight: number = 8;
  static readonly ActiveBarWidth: number = 4;
}
