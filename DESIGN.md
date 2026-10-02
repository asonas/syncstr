# Syncstr — Design

## この文書の使い方

画面の配置・文言・寸法・状態表現は、以下のプラットフォーム別方針を優先する。ブランド／アイコンの決定と、後半のSpliceのWeb向け参考資料は適用範囲が異なる。Webのpx値やページ構成をmacOSのpt値・ウィンドウ構成へそのまま転用しない。

## macOSのUI方針

### 情報と操作

- サイドバーで選択済みの内容を、本文の「アルバム」などの見出しで繰り返さない。「ライブラリ」「再生中」「再生キュー」など、操作や情報の理解に寄与しない見出しも置かない。削除時は見出し専用の余白も取り除く。
- 選択・再生の状態は背景、色、アイコンで伝える。見た目から分かる状態に「選択中」「再生中」という説明を重ねない。VoiceOverにはラベルと選択状態などのアクセシビリティ属性を提供する。
- 待機・送信・失敗など、次の操作の判断に必要な状態は表示する。状態テキストを一律に削除する規則ではない。
- 常設サイドバーにはアルバム・アーティスト・曲と、「音楽を追加」「ライブラリを更新」を置く。ブランド名を繰り返す見出しや、サイドバーを閉じるボタンは置かない。
- 接続先・アップロードトークンの保存とログアウトは設定画面へまとめる。ログアウトには確認を設ける。
- 音源のドロップは送信候補の一覧への追加とし、「アップロード」を押してから1件ずつ送信する。

### アルバム詳細

Music.appの情報配置を参考に、アートワークの隣へアルバム名、アーティスト、曲数をまとめ、その下に「再生」を置く。再生ボタンはアルバムのディスク番号・曲番号順の1曲目から再生する。曲一覧はその下へ直接続ける。

### 検索とウィンドウ

- 検索窓は右上に置き、表示中の項目に応じて「アルバムを検索」「アーティストを検索」「曲を検索」とする。
- フォーカスは入力欄の範囲で示す。フォーカスによって周囲に明るい帯が出たり、上部に不要な領域が増えたりしないことを実画面で確認する。
- サイドバーと本文の区切り線はウィンドウ上端まで連続させる。サイドバーの行は背景の余白を含めてクリックできるようにする。
- 検索窓の高さはNSSearchFieldの標準サイズから取得し、外枠だけを引き伸ばさない。macOS 26以降はextraLarge、それ以前はlargeを使用する。通常時・フォーカス時の入力文字、アイコン、フォーカス枠が同じ高さの中で揃うことを確認する。Splice参考資料のInput Fieldは文字サイズと余白の参考であり、macOS検索窓の固定高の指定ではない。

変更後の確認方法は [CODING_STANDARDS.md](CODING_STANDARDS.md) を参照する。

## 採用したブランド／アイコン配色

2026-10-02に、アイコンの意匠 **A2.3「水平のリズム」**、配色 **C2**、残像 **F2** を採用しました。[Figmaの採用案](https://www.figma.com/design/KtfBubkg9KiK5LuLHIm8Qt?node-id=12-2)を参照してください。

| 用途 | 色 | 適用範囲 |
|---|---|---|
| ブランドの藍色 | `#4338ca` | 採用アイコンの背景 |
| ブランドの淡い白 | `#eef2ff` | 採用アイコンのSと残像 |

この2色はアイコン用の組み合わせです。既存UIのSignal Blue `#528fff`、Button Blue `#1253ff`、Carbon／Graphiteの背景色を置き換える決定ではありません。以下のSplice参照資料にある「新しいアクセントカラーを追加しない」という規範はUIに適用し、採用アイコンにはこの配色を適用します。

### 残像の設定

256 × 256の座標系で、手前のSは不透明度100%・ブラーなしとし、背後に同じ形・同じ色のSを2層重ねます。

| レイヤー | 手前のSからの位置 | 不透明度 | ブラー半径 |
|---|---|---|---|
| 近い残像 | 右6・下6 | 42% | 2 |
| 遠い残像 | 右12・下12 | 20% | 4 |

重なり全体を中央に置くため、手前のSを単層時の位置から左6・上6へ移動します。サイズ変更時は、位置とブラー半径も同じ倍率で拡縮します。

### 判断の根拠と実装状態

- 不透明な `#eef2ff` と `#4338ca` の輝度コントラスト比は約7.07:1です。これは[WCAGの相対輝度とコントラスト比の定義](https://www.w3.org/TR/WCAG22/#dfn-relative-luminance)による計算値であり、ブランドの独自性や美しさを評価する点数ではありません。半透明の残像には同じ値を適用できません。
- 藍色 `#4338ca` をGraphite `#232426` 上のマークに使うと約1.97:1になるため、採用アイコンでは淡い白と組み合わせます。
- Figma上で意匠を選定済みです。OS別素材への仕上げとアプリへの組み込みは未実施です。Apple向けの仕上げでは、[Icon Composerの公式説明](https://developer.apple.com/videos/play/wwdc2025/361/)に沿って原図形のレイヤーを保ち、ブラーなどの効果を別途調整します。

## Splice — Style Reference
> midnight recording studio — a dark, weightless space where the only thing that ever gets loud is the music.

**Theme:** dark

Source measurements are normalized; roles and recommendations are interpreted. Font summary lists are independent, not paired by position. HTML examples are reconstructions, not source components.

Splice operates as a midnight recording studio: deep charcoal canvases, near-borderless surfaces, and a single electric blue accent that cuts through the darkness like a signal light. Typography splits between SoehneBreit at whisper-weight for editorial headlines and Inter Variable as the dense workhorse, creating a deliberate contrast between performance and utility. Components stay flat and weightless — cards sit on near-identical surface tones, shadows are replaced by hairline inset strokes, and elevation comes from the photography itself. Color is rationed: one blue carries links and interactive elements, a saturated yellow-green appears as rare text punctuation, and everything else recedes into grayscale. The product — sound — is the only thing that ever gets loud.

## Tokens — Colors

| Name | Value | Token | Role |
|------|-------|-------|------|
| Signal Blue | `#528fff` | `--color-signal-blue` | Violet supporting accent for decorative details and low-frequency emphasis. Do not promote it to the primary CTA color |
| Button Blue | `#1253ff` | `--color-button-blue` | Violet supporting accent for decorative details and low-frequency emphasis. Do not promote it to the primary CTA color |
| Voltage Yellow | `#f1f607` | `--color-voltage-yellow` | Rare text accent — highlight punctuation, featured labels, emphasis. Used sparingly, only when a word needs to flash against the dark canvas. Never on backgrounds |
| Carbon | `#121214` | `--color-carbon` | Primary page canvas, card surfaces, input fields, footer. The dominant working surface at 425 occurrences across every context |
| Obsidian | `#000000` | `--color-obsidian` | Deepest dark — image containers, nav surface, full-bleed backgrounds. Creates the bottom of the surface stack |
| Platinum | `#ffffff` | `--color-platinum` | Primary text, inverted button text, icon fills. The only true white in the system; appears 1506 times across every text context |
| Graphite | `#232426` | `--color-graphite` | Dominant canvas background, secondary button surface. Sits one step lighter than Carbon, used when a surface needs to feel like a different plane without using shadow |
| Fog | `#a6a8ad` | `--color-fog` | Muted text, nav items, secondary labels, inactive links. The first step down from white in the type hierarchy |
| Ash | `#c8c9cc` | `--color-ash` | Button borders, icon strokes, hairline dividers, ghost control outlines. The border that doesn't feel like a border |
| Slate | `#63656d` | `--color-slate` | Borders, dividers, inactive controls. Darker than Ash for when a divider needs to recede further |
| Iron | `#45464d` | `--color-iron` | Elevated surfaces, button borders, nav separators. The highest dark in the stack — used for the 1px inset stroke that replaces shadows |

## Tokens — Typography

### InterVariable (custom) — Workhorse for all UI text — body, nav, buttons, inputs, cards, footer. The variable axis allows weight shifts (400→500→600→700) within a single family. Universal -0.015em tracking creates a compact, efficient reading rhythm across every size. · `--font-intervariable-custom`
- **Substitute:** Inter
- **Weights:** 400, 500, 600, 700
- **Sizes:** 12, 13, 14, 16, 18, 20, 26
- **Line height:** 1.20, 1.25, 1.43, 1.50
- **Letter spacing:** -0.0150em
- **Role:** Workhorse for all UI text — body, nav, buttons, inputs, cards, footer. The variable axis allows weight shifts (400→500→600→700) within a single family. Universal -0.015em tracking creates a compact, efficient reading rhythm across every size.

### SoehneBreit (custom) — Editorial display headlines. The wider, geometric cut of SoehneBreit at weight 400 creates a distinctive voice — headlines don't shout, they announce with quiet authority. The 0.071em tracking (applied at 14px) appears on uppercase eyebrow labels, creating the system's only wide-tracked text. Weight 400 only — bold is never used. · `--font-soehnebreit-custom`
- **Substitute:** Inter (with +2% horizontal scaling and 0.071em tracking on uppercase)
- **Weights:** 400
- **Sizes:** 14, 28, 36, 48, 54
- **Line height:** 1.25, 1.43
- **Letter spacing:** -0.0150em, 0.0710em
- **Role:** Editorial display headlines. The wider, geometric cut of SoehneBreit at weight 400 creates a distinctive voice — headlines don't shout, they announce with quiet authority. The 0.071em tracking (applied at 14px) appears on uppercase eyebrow labels, creating the system's only wide-tracked text. Weight 400 only — bold is never used.

### Soehne (custom) — Subheadings — bridges the gap between SoehneBreit display and Inter body. Used at 20px for secondary headings that need editorial weight without display scale. · `--font-soehne-custom`
- **Substitute:** Inter
- **Weights:** 400
- **Sizes:** 20
- **Line height:** 1.25
- **Letter spacing:** -0.0150em
- **Role:** Subheadings — bridges the gap between SoehneBreit display and Inter body. Used at 20px for secondary headings that need editorial weight without display scale.

### Type Scale

| Role | Family | Weight | Size | Line Height | Letter Spacing | Token |
|------|--------|--------|------|-------------|----------------|-------|
| caption | — | — | 12px | 1.2 | -0.18px | `--text-caption` |
| body-sm | — | — | 14px | 1.43 | -0.21px | `--text-body-sm` |
| body | — | — | 16px | 1.5 | -0.24px | `--text-body` |
| subheading | — | — | 20px | 1.25 | -0.3px | `--text-subheading` |
| heading-sm | — | — | 28px | 1.25 | -0.42px | `--text-heading-sm` |
| heading | — | — | 36px | 1.25 | -0.54px | `--text-heading` |
| heading-lg | — | — | 48px | 1.25 | -0.72px | `--text-heading-lg` |
| display | — | — | 54px | 1.25 | -0.81px | `--text-display` |

## Tokens — Spacing & Shapes

**Base unit:** 4px

**Density:** comfortable

### Spacing Scale

| Name | Value | Token |
|------|-------|-------|
| 4 | 4px | `--spacing-4` |
| 8 | 8px | `--spacing-8` |
| 16 | 16px | `--spacing-16` |
| 20 | 20px | `--spacing-20` |
| 32 | 32px | `--spacing-32` |
| 48 | 48px | `--spacing-48` |
| 64 | 64px | `--spacing-64` |
| 80 | 80px | `--spacing-80` |
| 120 | 120px | `--spacing-120` |

### Border Radius

| Element | Value |
|---------|-------|
| nav | 1440px |
| cards | 4px |
| images | 4px |
| inputs | 4px |
| buttons | 8px |
| pill-buttons | 60px |

### Shadows

| Name | Value | Token |
|------|-------|-------|
| subtle | `rgba(0, 0, 0, 0.07) 0px 0px 0px 1px inset` | `--shadow-subtle` |

### Layout

- **Section gap:** 80px
- **Card padding:** 20-32px
- **Element gap:** 8-16px

## Components

### Promotional Banner
**Role:** Top-of-page announcement strip

Full-width #528fff background, centered white text at 14px Inter weight 400, with an inline link. Padding 8-14px vertical. Sits above the navigation as a separate band.

### Navigation Bar
**Role:** Primary site navigation

Black (#000000) background, sticky to top. Logo left, link group center (Fog #a6a8ad, 14px Inter, 16-20px horizontal spacing), utility actions right. Inner pill elements use 1440px radius (fully rounded). Height approximately 60px.

### Filled Button (Primary)
**Role:** Interactive action trigger

#1253ff background, #ffffff text, 8px border-radius, 16px vertical / 20px horizontal padding. Inter weight 500-600 at 14px. The system's solid interactive element — deeper and more grounded than the Signal Blue links.

### Ghost Button
**Role:** Secondary interactive trigger

Transparent background, #c8c9cc or #ffffff border (1px), #ffffff text, 8px border-radius, 8px vertical / 20px horizontal padding. Inter weight 400-500 at 14px. Used for actions that should not compete with the filled button.

### Pill Button
**Role:** Rounded utility button

60px border-radius, compact padding (8-10px vertical, 16-20px horizontal). Used for tag-like actions, filter pills, and small interactive chips. Typically #ffffff fill with #000000 text when inverted, or transparent with #ffffff text on dark.

### Hero Section
**Role:** Full-bleed landing visual

Full-viewport-width photograph (no radius, edge-to-edge). Overlaid text sits left-aligned, 48-54px SoehneBreit weight 400 in #ffffff with -0.72 to -0.81px letter-spacing. Body text at 16-18px Inter in #ffffff or rgba white. A filled blue button sits below the headline at 20px from the last line.

### Content Card
**Role:** Grouped content surface

#121214 background, 4px border-radius, 20-32px padding, optional 1px #232426 or #45464d hairline border. No drop shadow. Content sits flat on the canvas, separated only by the surface tone shift and border line.

### Input Field
**Role:** Text input control

#121214 background, 1px #45464d border, 4px border-radius, 12-14px vertical / 16px horizontal padding. Inter weight 400 at 14px. Placeholder text in Fog #a6a8ad. No focus glow — the border simply shifts to Signal Blue #528fff on focus.

### Inline Link
**Role:** Text-level navigation

#528fff color, Inter weight 400-500 at 14-16px, no underline by default. Underline appears on hover at 1px offset. The system's most-used color — 351 occurrences.

### Footer
**Role:** Site-bottom content

#000000 background, 48px+ vertical padding, Inter 12-14px in Fog #a6a8ad for body text. Links in #ffffff. Minimal visual weight — the footer recedes.

## Do's and Don'ts

### Do
- Use #528fff Signal Blue for all links and interactive text — it is the system's only persistent color voice
- Apply -0.015em letter-spacing to all text at all sizes for the compact reading rhythm
- Use SoehneBreit weight 400 for headlines — never bold, the whisper-weight is the voice
- Separate surfaces with 1px borders in #45464d or #232426, never with drop shadows
- Use 8px radius for standard buttons and 60px for pill-shaped interactive elements
- Apply 0.071em tracking to uppercase SoehneBreit labels at 14px for the editorial eyebrow pattern
- Let photography provide all visual elevation — full-bleed images carry the weight that shadows would

### Don't
- Never use #f1f607 Voltage Yellow on backgrounds — it is text-only punctuation
- Don't add drop shadows to cards or panels — the system is intentionally flat
- Never set SoehneBreit to bold weight — it only exists at 400 in this system
- Don't introduce new accent colors — the palette is grayscale plus two signals (blue, yellow-green)
- Avoid pure white backgrounds — the canvas is always Carbon #121214 or Graphite #232426
- Don't center-align body text — left-align for editorial reading rhythm
- Never use more than one chromatic color per component — the system rations color

## Surfaces

| Level | Name | Value | Purpose |
|-------|------|-------|---------|
| 0 | Graphite Canvas | `#232426` | Page background — the dominant working surface |
| 1 | Carbon | `#121214` | Card surfaces, sections, input fields |
| 2 | Obsidian | `#000000` | Deepest dark — full-bleed images, nav surface |
| 3 | Iron | `#45464d` | Elevated borders, inset strokes, the system's only 'raised' element |

## Elevation

Elevation is intentionally absent. The only shadow in the system is a 1px inset stroke (rgba(0,0,0,0.07) 0px 0px 0px 1px inset) used to create hairline separation on dark surfaces. Cards don't float — they sit on near-identical tones, differentiated only by the 1px border between Carbon and the slightly lighter Iron. This creates a flat, weightless feel appropriate for a creative tool that needs to stay out of the way of the work. If something needs to feel important, it gets a photograph, not a shadow.

## Imagery

Photography is the hero: full-bleed, atmospheric, and moody. The signature treatment is interior spaces — rooms, studios, domestic environments — captured in dramatic colored light (the green-tinted room in the hero is characteristic). Photography is high-key in color but low-key in contrast, creating a cinematic, almost editorial feel. Images are edge-to-edge with 4px radius or no radius at all, never contained in rounded cards. Product screenshots and illustrations are absent — the photography IS the product communication. The visual density is image-heavy at the hero level, transitioning to text-dominant in body sections.

## Layout

Full-bleed layout with no content max-width constraint — the nav, hero, and footer all span the full viewport. The hero is a single full-bleed photograph with left-aligned text overlaid in the lower-left quadrant, following a classic editorial pattern. Body content sits centered or left-aligned within the full-width canvas. The promotional banner at the very top is a separate full-width band. Section rhythm is spacious — 80px between major sections, with breathing room around photography. Navigation is a dark sticky top bar with a separated promotional strip above it. The grid is not rigidly columnar at the page level; content blocks are positioned with generous margins, and the only grid structure appears in card clusters and feature lists.

## Agent Prompt Guide

primary action: no distinct CTA color
**Quick Color Reference**
- text: #ffffff
- background: #121214
- border: #45464d
- accent: #528fff
- button fill: #1253ff
- highlight: #f1f607

**Example Component Prompts**

1. Create a full-bleed hero section: a large dark-toned photograph filling the entire viewport with no border-radius. Overlaid in the lower-left, a headline at 54px SoehneBreit weight 400, #ffffff, letter-spacing -0.81px. Below it, a filled blue button (#1253ff background, #ffffff text, 8px radius, 16px 20px padding, Inter weight 500 at 14px).

2. Create a content card: #121214 background, 4px border-radius, 1px #45464d border, 24px padding. Headline at 28px SoehneBreit weight 400 in #ffffff, body text at 16px Inter weight 400 in Fog #a6a8ad. No drop shadow.

3. Create a ghost button: transparent background, 1px #c8c9cc border, #ffffff text, 8px radius, 8px 20px padding, Inter weight 400 at 14px. Include a small play icon (▷) in white to the left of the text.

4. Create a navigation bar: #000000 background, 60px height, sticky to top. Logo (wordmark in #ffffff, Inter weight 700 at 16px) on the left, nav links (#a6a8ad, Inter weight 400 at 14px, 20px horizontal gap) in the center, and a filled blue button (#1253ff, 8px radius, Inter 14px weight 500) on the right.

5. Create an input field: #121214 background, 1px #45464d border, 4px border-radius, 12px 16px padding. Placeholder text 'Search samples...' in #a6a8ad, Inter weight 400 at 14px. On focus, border shifts to #528fff.

## Similar Brands

- **Spotify** — Dark-mode media platform with a near-monochrome palette and a single green accent — the same rationed-color approach where the product (audio) is the only loud element
- **Bandcamp** — Dark music marketplace with editorial typography and full-bleed album photography — similar weightless surface treatment with hairline separation instead of shadows
- **Native Instruments** — Music production tools with dark UI, condensed type, and minimal chrome — the same professional-tools-meets-creative-tool balance
- **Ableton** — Dark-mode creative software with weightless surfaces and photography-led marketing — the same philosophy of letting the medium (sound/light) do the visual heavy lifting

## Quick Start

### CSS Custom Properties

```css
:root {
  /* Colors */
  --color-signal-blue: #528fff;
  --color-button-blue: #1253ff;
  --color-voltage-yellow: #f1f607;
  --color-carbon: #121214;
  --color-obsidian: #000000;
  --color-platinum: #ffffff;
  --color-graphite: #232426;
  --color-fog: #a6a8ad;
  --color-ash: #c8c9cc;
  --color-slate: #63656d;
  --color-iron: #45464d;

  /* Typography — Font Families */
  --font-intervariable-custom: 'InterVariable (custom)', ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
  --font-soehnebreit-custom: 'SoehneBreit (custom)', ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
  --font-soehne-custom: 'Soehne (custom)', ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;

  /* Typography — Scale */
  --text-caption: 12px;
  --leading-caption: 1.2;
  --tracking-caption: -0.18px;
  --text-body-sm: 14px;
  --leading-body-sm: 1.43;
  --tracking-body-sm: -0.21px;
  --text-body: 16px;
  --leading-body: 1.5;
  --tracking-body: -0.24px;
  --text-subheading: 20px;
  --leading-subheading: 1.25;
  --tracking-subheading: -0.3px;
  --text-heading-sm: 28px;
  --leading-heading-sm: 1.25;
  --tracking-heading-sm: -0.42px;
  --text-heading: 36px;
  --leading-heading: 1.25;
  --tracking-heading: -0.54px;
  --text-heading-lg: 48px;
  --leading-heading-lg: 1.25;
  --tracking-heading-lg: -0.72px;
  --text-display: 54px;
  --leading-display: 1.25;
  --tracking-display: -0.81px;

  /* Typography — Weights */
  --font-weight-regular: 400;
  --font-weight-medium: 500;
  --font-weight-semibold: 600;
  --font-weight-bold: 700;

  /* Spacing */
  --spacing-unit: 4px;
  --spacing-4: 4px;
  --spacing-8: 8px;
  --spacing-16: 16px;
  --spacing-20: 20px;
  --spacing-32: 32px;
  --spacing-48: 48px;
  --spacing-64: 64px;
  --spacing-80: 80px;
  --spacing-120: 120px;

  /* Layout */
  --section-gap: 80px;
  --card-padding: 20-32px;
  --element-gap: 8-16px;

  /* Border Radius */
  --radius-md: 4px;
  --radius-lg: 8px;
  --radius-2xl: 16px;
  --radius-full: 60px;
  --radius-full-2: 100px;
  --radius-full-3: 128px;
  --radius-full-4: 180px;
  --radius-full-5: 1440px;

  /* Named Radii */
  --radius-nav: 1440px;
  --radius-cards: 4px;
  --radius-images: 4px;
  --radius-inputs: 4px;
  --radius-buttons: 8px;
  --radius-pill-buttons: 60px;

  /* Shadows */
  --shadow-subtle: rgba(0, 0, 0, 0.07) 0px 0px 0px 1px inset;

  /* Surfaces */
  --surface-graphite-canvas: #232426;
  --surface-carbon: #121214;
  --surface-obsidian: #000000;
  --surface-iron: #45464d;
}
```

### Tailwind v4

```css
@theme {
  /* Colors */
  --color-signal-blue: #528fff;
  --color-button-blue: #1253ff;
  --color-voltage-yellow: #f1f607;
  --color-carbon: #121214;
  --color-obsidian: #000000;
  --color-platinum: #ffffff;
  --color-graphite: #232426;
  --color-fog: #a6a8ad;
  --color-ash: #c8c9cc;
  --color-slate: #63656d;
  --color-iron: #45464d;

  /* Typography */
  --font-intervariable-custom: 'InterVariable (custom)', ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
  --font-soehnebreit-custom: 'SoehneBreit (custom)', ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
  --font-soehne-custom: 'Soehne (custom)', ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;

  /* Typography — Scale */
  --text-caption: 12px;
  --leading-caption: 1.2;
  --tracking-caption: -0.18px;
  --text-body-sm: 14px;
  --leading-body-sm: 1.43;
  --tracking-body-sm: -0.21px;
  --text-body: 16px;
  --leading-body: 1.5;
  --tracking-body: -0.24px;
  --text-subheading: 20px;
  --leading-subheading: 1.25;
  --tracking-subheading: -0.3px;
  --text-heading-sm: 28px;
  --leading-heading-sm: 1.25;
  --tracking-heading-sm: -0.42px;
  --text-heading: 36px;
  --leading-heading: 1.25;
  --tracking-heading: -0.54px;
  --text-heading-lg: 48px;
  --leading-heading-lg: 1.25;
  --tracking-heading-lg: -0.72px;
  --text-display: 54px;
  --leading-display: 1.25;
  --tracking-display: -0.81px;

  /* Spacing */
  --spacing-4: 4px;
  --spacing-8: 8px;
  --spacing-16: 16px;
  --spacing-20: 20px;
  --spacing-32: 32px;
  --spacing-48: 48px;
  --spacing-64: 64px;
  --spacing-80: 80px;
  --spacing-120: 120px;

  /* Border Radius */
  --radius-md: 4px;
  --radius-lg: 8px;
  --radius-2xl: 16px;
  --radius-full: 60px;
  --radius-full-2: 100px;
  --radius-full-3: 128px;
  --radius-full-4: 180px;
  --radius-full-5: 1440px;

  /* Shadows */
  --shadow-subtle: rgba(0, 0, 0, 0.07) 0px 0px 0px 1px inset;
}
```
