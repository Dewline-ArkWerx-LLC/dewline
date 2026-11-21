use std::panic::{self, AssertUnwindSafe};
use std::sync::mpsc::{self, RecvTimeoutError};
use std::sync::{Arc, LazyLock};
use std::thread;
use std::time::{Duration, SystemTime};

use dewline_core::export;
use mermaid_rs_renderer::{Layout, LayoutConfig, Theme, compute_layout};
use ratex_layout::LayoutOptions;
use ratex_types::color::Color;
use ratex_types::display_item::DisplayList;
use resvg::{tiny_skia, usvg};

mod agentfiles;
mod agents;
mod allocator;
mod docx;
mod engine;
mod git;
mod highlight;
mod markdown;
mod notelinks;
mod save;
mod search;
#[cfg(feature = "collab")]
mod sync;
mod system;

uniffi::setup_scaffolding!();

#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum RenderError {
    #[error("the source is over 50 KB")]
    TooLarge,
    #[error("rendering took over 250 ms")]
    TooSlow,
    #[error("{message}")]
    Invalid { message: String },
}

/// The editor theme's colors for a diagram, each sRGB 0xRRGGBBAA.
#[derive(Clone, Copy, uniffi::Record)]
pub struct DiagramColors {
    pub paper: u32,
    pub ink: u32,
    pub ink2: u32,
    pub accent: u32,
    pub fill: u32,
}

impl DiagramColors {
    /// The renderer's theme in these colors for a diagram of `kind`. On a dark page, where the ink is lighter than
    /// the paper, pie slices and git branches take the renderer's dark palettes and `LIGHT_ONLY` kinds keep its light
    /// theme.
    fn theme(&self, kind: &str) -> Theme {
        let lightness = |color: u32| (color >> 24) + ((color >> 16) & 0xff) + ((color >> 8) & 0xff);
        let modern = Theme::modern();
        let base = if lightness(self.ink) <= lightness(self.paper) {
            modern
        } else if LIGHT_ONLY.contains(&kind) {
            return modern;
        } else {
            Theme {
                font_family: modern.font_family,
                font_size: modern.font_size,
                ..Theme::dark()
            }
        };
        let [paper, ink, ink2, accent, fill] =
            [self.paper, self.ink, self.ink2, self.accent, self.fill]
                .map(|color| format!("#{color:08x}"));
        Theme {
            background: paper.clone(),
            edge_label_background: paper.clone(),
            cluster_background: paper.clone(),
            tertiary_color: paper,
            primary_text_color: ink.clone(),
            text_color: ink.clone(),
            git_commit_label_color: ink.clone(),
            git_tag_label_color: ink.clone(),
            pie_title_text_color: ink.clone(),
            pie_legend_text_color: ink,
            sequence_note_border: accent,
            primary_border_color: ink2.clone(),
            cluster_border: ink2.clone(),
            sequence_actor_border: ink2.clone(),
            sequence_actor_line: ink2.clone(),
            sequence_activation_border: ink2.clone(),
            git_tag_label_border: ink2.clone(),
            pie_outer_stroke_color: ink2.clone(),
            line_color: ink2,
            primary_color: fill.clone(),
            secondary_color: fill.clone(),
            sequence_actor_fill: fill.clone(),
            sequence_note_fill: fill.clone(),
            sequence_activation_fill: fill.clone(),
            git_commit_label_background: fill.clone(),
            git_tag_label_background: fill,
            ..base
        }
    }
}

/// A diagram or formula as outlines in points from its top left, which the app fills at the screen's scale.
#[derive(uniffi::Record)]
pub struct Drawing {
    pub width: f32,
    pub height: f32,
    /// How far a formula reaches below its baseline.
    pub depth: f32,
    pub shapes: Vec<Shape>,
    pub insets: Vec<Inset>,
}

/// An outline filled in `color` (sRGB 0xRRGGBBAA). Each verb (0 move, 1 line, 2 quad, 3 cubic, 4 close) takes 1, 1,
/// 2, 3 or 0 of the x, y pairs in `points`.
#[derive(uniffi::Record)]
pub struct Shape {
    pub color: u32,
    pub even_odd: bool,
    pub verbs: Vec<u8>,
    pub points: Vec<f32>,
}

/// A PNG or JPEG a diagram places in a rectangle, such as a C4 person.
#[derive(uniffi::Record)]
pub struct Inset {
    pub x: f32,
    pub y: f32,
    pub width: f32,
    pub height: f32,
    pub data: Vec<u8>,
}

// The diagram types mermaid-rs-renderer parses. A source without one of these
// headers would still render: the renderer reads anything shaped like an edge
// as a flowchart, so newer types come out as nonsense instead of an error.
const HEADERS: [&str; 29] = [
    "flowchart",
    "graph",
    "sequencediagram",
    "classdiagram",
    "statediagram",
    "erdiagram",
    "pie",
    "mindmap",
    "journey",
    "timeline",
    "gantt",
    "requirementdiagram",
    "gitgraph",
    "c4",
    "c4context",
    "c4container",
    "c4component",
    "c4dynamic",
    "c4deployment",
    "sankey",
    "quadrantchart",
    "zenuml",
    "block",
    "packet",
    "kanban",
    "architecture",
    "radar",
    "treemap",
    "xychart",
];
// Diagram types the renderer draws for a white page: on a dark one, some of their labels, lines or flows vanish.
const LIGHT_ONLY: [&str; 11] = [
    "c4",
    "c4context",
    "c4container",
    "c4component",
    "c4dynamic",
    "c4deployment",
    "quadrantchart",
    "radar",
    "requirementdiagram",
    "sankey",
    "timeline",
];
const MAX_SOURCE: usize = 50 * 1024;
const MAX_PIXELS: u32 = 16 << 20;
const BUDGET: Duration = Duration::from_millis(250);
// The editor narrows a diagram to its text column, about 590 pt at the default
// measure. A flowchart that would draw its labels under 11 pt there folds into
// bands at 3:2 when that makes it narrower (the renderer folds no subgraphs).
const COLUMN: f32 = 590.0;
const LEAST_LABEL: f32 = 11.0;
const FOLD_RATIO: f32 = 1.5;

static FONTS: LazyLock<Arc<usvg::fontdb::Database>> = LazyLock::new(|| {
    let mut fonts = usvg::fontdb::Database::new();
    fonts.load_system_fonts();
    Arc::new(fonts)
});

// ratex builds its symbol tables and loads its fonts on the first formula,
// which can take the whole budget on a loaded machine; the budget is for the
// formula.
static MATH_FONTS: LazyLock<()> = LazyLock::new(|| {
    let _ = math_outlines(r"\frac{x}{1}", 20.0, 0);
});

// mermaid-rs-renderer scans the system fonts on its first text measurement,
// which takes about the whole budget; the budget is for the diagram.
static MERMAID_FONTS: LazyLock<()> = LazyLock::new(|| {
    let _ = mermaid_rs_renderer::render("flowchart LR\n  a");
});

/// Runs `work` on its own thread and stops waiting after the budget. Neither
/// renderer can be cancelled, so a render that overruns finishes unobserved.
fn within_budget<T: Send + 'static>(
    budget: Duration,
    work: impl FnOnce() -> Result<T, String> + Send + 'static,
) -> Result<T, RenderError> {
    let (sender, receiver) = mpsc::channel();
    thread::spawn(move || sender.send(work()));
    match receiver.recv_timeout(budget) {
        Ok(result) => result.map_err(|message| RenderError::Invalid { message }),
        Err(RecvTimeoutError::Timeout) => Err(RenderError::TooSlow),
        Err(RecvTimeoutError::Disconnected) => Err(RenderError::Invalid {
            message: "the renderer crashed".into(),
        }),
    }
}

fn render_mermaid(source: String, colors: DiagramColors) -> Result<String, RenderError> {
    mermaid_within(BUDGET, source, colors)
}

#[uniffi::export]
pub fn draw_mermaid(source: String, colors: DiagramColors) -> Result<Drawing, RenderError> {
    let tree = parse(&render_mermaid(source, colors)?)?;
    let size = tree.size();
    Ok(outlines(&tree, size.width(), size.height(), 0.0))
}

fn mermaid_within(
    budget: Duration,
    source: String,
    colors: DiagramColors,
) -> Result<String, RenderError> {
    if source.len() > MAX_SOURCE {
        return Err(RenderError::TooLarge);
    }
    let mut frontmatter = false;
    let header = source.lines().map(str::trim).find(|line| {
        frontmatter ^= *line == "---";
        !frontmatter && !line.is_empty() && *line != "---" && !line.starts_with("%%")
    });
    let kind = header.map_or("", |line| {
        line.split(|c: char| !c.is_ascii_alphanumeric())
            .next()
            .unwrap_or("")
    });
    let known = kind.to_ascii_lowercase();
    if !HEADERS.contains(&known.as_str()) {
        return Err(RenderError::Invalid {
            message: format!("unsupported diagram type '{kind}'"),
        });
    }
    LazyLock::force(&MERMAID_FONTS);
    let theme = colors.theme(&known);
    let flowchart = matches!(known.as_str(), "flowchart" | "graph");
    within_budget(budget, move || {
        let graph = mermaid_rs_renderer::parse_mermaid_strict(&source)
            .map_err(|error| error.to_string())?
            .graph;
        let width = |layout: &Layout, config: &LayoutConfig| {
            mermaid_rs_renderer::measure_svg_dimensions(layout, config, None).width
        };
        let mut config = LayoutConfig::default();
        let mut layout = compute_layout(&graph, &theme, &config);
        if flowchart && width(&layout, &config) > COLUMN * theme.font_size / LEAST_LABEL {
            let folded_config = LayoutConfig {
                preferred_aspect_ratio: Some(FOLD_RATIO),
                ..LayoutConfig::default()
            };
            let folded = compute_layout(&graph, &theme, &folded_config);
            if width(&folded, &folded_config) < width(&layout, &config) {
                (layout, config) = (folded, folded_config);
            }
        }
        if flowchart {
            clear_labels(&mut layout);
        }
        Ok(mermaid_rs_renderer::render_svg(&layout, &theme, &config))
    })
}

/// Moves each edge label that covers a node, an earlier label or another edge to the first clear spot beside its edge,
/// at the middle of a segment, longest first. mermaid-rs-renderer 0.3.1 can set a label over the node its edge enters,
/// and the node, drawn later, hides the label's first words.
fn clear_labels(layout: &mut Layout) {
    const PAD: f32 = 6.0;
    let (width, height) = (layout.width, layout.height);
    let nodes: Vec<[f32; 4]> = layout
        .nodes
        .values()
        .filter(|node| !node.hidden)
        .map(|node| [node.x, node.y, node.x + node.width, node.y + node.height])
        .collect();
    // Each edge's path as points about 4 pt apart.
    let paths: Vec<Vec<(f32, f32)>> = layout
        .edges
        .iter()
        .map(|edge| {
            edge.points
                .windows(2)
                .flat_map(|pair| {
                    let ((x0, y0), (x1, y1)) = (pair[0], pair[1]);
                    let steps = ((x1 - x0).hypot(y1 - y0) / 4.0).ceil().max(1.0) as usize;
                    (0..=steps).map(move |step| {
                        let t = step as f32 / steps as f32;
                        (x0 + (x1 - x0) * t, y0 + (y1 - y0) * t)
                    })
                })
                .collect()
        })
        .collect();
    let mut placed: Vec<[f32; 4]> = Vec::new();
    for (index, edge) in layout.edges.iter_mut().enumerate() {
        let (Some(label), Some(anchor)) = (&edge.label, edge.label_anchor) else {
            continue;
        };
        let (w, h) = (label.width + 2.0 * PAD, label.height + 2.0 * PAD);
        let rect = |(x, y): (f32, f32)| [x - w / 2.0, y - h / 2.0, x + w / 2.0, y + h / 2.0];
        // Nodes and earlier labels it covers, then points of other edges inside it; `None` outside the diagram.
        let cost = |center| {
            let [left, top, right, bottom] = rect(center);
            if left < 0.0 || top < 0.0 || right > width || bottom > height {
                return None;
            }
            let inside = |&(x, y): &(f32, f32)| left < x && x < right && top < y && y < bottom;
            let covered = nodes
                .iter()
                .chain(&placed)
                .filter(|other| {
                    left < other[2] && other[0] < right && top < other[3] && other[1] < bottom
                })
                .count();
            let crossed = paths
                .iter()
                .enumerate()
                .filter(|&(other, _)| other != index)
                .map(|(_, path)| path.iter().filter(|point| inside(point)).count())
                .sum::<usize>();
            Some((covered, crossed))
        };
        let here = cost(anchor);
        if here != Some((0, 0)) {
            let mut segments: Vec<((f32, f32), (f32, f32))> = edge
                .points
                .windows(2)
                .map(|pair| (pair[0], pair[1]))
                .collect();
            let length = |((x0, y0), (x1, y1)): &((f32, f32), (f32, f32))| (x1 - x0).hypot(y1 - y0);
            segments.sort_by(|a, b| length(b).total_cmp(&length(a)));
            let best = segments
                .iter()
                .flat_map(|&((x0, y0), (x1, y1))| {
                    let (x, y) = ((x0 + x1) / 2.0, (y0 + y1) / 2.0);
                    if (x1 - x0).abs() >= (y1 - y0).abs() {
                        [(x, y + h / 2.0), (x, y - h / 2.0)]
                    } else {
                        [(x + w / 2.0, y), (x - w / 2.0, y)]
                    }
                })
                .filter_map(|spot| Some((cost(spot)?, spot)))
                .min_by_key(|&(cost, _)| cost);
            if let Some((cost, spot)) = best
                && here.is_none_or(|here| cost < here)
            {
                edge.label_anchor = Some(spot);
            }
        }
        if let Some(anchor) = edge.label_anchor {
            placed.push(rect(anchor));
        }
    }
}

fn parse(svg: &str) -> Result<usvg::Tree, RenderError> {
    let options = usvg::Options {
        fontdb: FONTS.clone(),
        ..Default::default()
    };
    usvg::Tree::from_str(svg, &options).map_err(|error| RenderError::Invalid {
        message: error.to_string(),
    })
}

/// The tree's filled and stroked paths, its text as glyph outlines, and its embedded pictures, stretched to
/// `width` by `height` points.
fn outlines(tree: &usvg::Tree, width: f32, height: f32, depth: f32) -> Drawing {
    let mut drawing = Drawing {
        width,
        height,
        depth,
        shapes: Vec::new(),
        insets: Vec::new(),
    };
    let size = tree.size();
    let fit = tiny_skia::Transform::from_scale(width / size.width(), height / size.height());
    collect(tree.root(), 1.0, fit, &mut drawing);
    drawing
}

fn collect(group: &usvg::Group, opacity: f32, fit: tiny_skia::Transform, drawing: &mut Drawing) {
    let opacity = opacity * group.opacity().get();
    for node in group.children() {
        match node {
            usvg::Node::Group(group) => collect(group, opacity, fit, drawing),
            usvg::Node::Text(text) => collect(text.flattened(), opacity, fit, drawing),
            usvg::Node::Path(path) if path.is_visible() => {
                let to = path.abs_transform().post_concat(fit);
                let fill = path.fill().and_then(|fill| {
                    let outline = path.data().clone().transform(to)?;
                    Some((
                        fill.paint(),
                        fill.opacity(),
                        fill.rule() == usvg::FillRule::EvenOdd,
                        outline,
                    ))
                });
                let stroke = path.stroke().and_then(|stroke| {
                    let outline = path
                        .data()
                        .stroke(&stroke.to_tiny_skia(), 4.0)?
                        .transform(to)?;
                    Some((stroke.paint(), stroke.opacity(), false, outline))
                });
                let mut layers = [fill, stroke];
                if path.paint_order() == usvg::PaintOrder::StrokeAndFill {
                    layers.reverse();
                }
                for (paint, alpha, even_odd, outline) in layers.into_iter().flatten() {
                    let Some(color) = rgba(paint, alpha.get() * opacity) else {
                        continue;
                    };
                    let mut shape = Shape {
                        color,
                        even_odd,
                        verbs: Vec::new(),
                        points: Vec::new(),
                    };
                    for segment in outline.segments() {
                        let (verb, points) = match segment {
                            tiny_skia::PathSegment::MoveTo(point) => (0, vec![point]),
                            tiny_skia::PathSegment::LineTo(point) => (1, vec![point]),
                            tiny_skia::PathSegment::QuadTo(control, point) => {
                                (2, vec![control, point])
                            }
                            tiny_skia::PathSegment::CubicTo(first, second, point) => {
                                (3, vec![first, second, point])
                            }
                            tiny_skia::PathSegment::Close => (4, vec![]),
                        };
                        shape.verbs.push(verb);
                        shape
                            .points
                            .extend(points.iter().flat_map(|point| [point.x, point.y]));
                    }
                    drawing.shapes.push(shape);
                }
            }
            usvg::Node::Image(image) => {
                if let usvg::ImageKind::PNG(data) | usvg::ImageKind::JPEG(data) = image.kind()
                    && let Some(rect) = image.abs_bounding_box().transform(fit)
                {
                    drawing.insets.push(Inset {
                        x: rect.x(),
                        y: rect.y(),
                        width: rect.width(),
                        height: rect.height(),
                        data: data.to_vec(),
                    });
                }
            }
            usvg::Node::Path(_) => {}
        }
    }
}

/// A solid paint, or a gradient's first stop, at `opacity`; nothing for a pattern.
fn rgba(paint: &usvg::Paint, opacity: f32) -> Option<u32> {
    let (color, opacity) = match paint {
        usvg::Paint::Color(color) => (*color, opacity),
        usvg::Paint::LinearGradient(gradient) => {
            let stop = gradient.stops().first()?;
            (stop.color(), opacity * stop.opacity().get())
        }
        usvg::Paint::RadialGradient(gradient) => {
            let stop = gradient.stops().first()?;
            (stop.color(), opacity * stop.opacity().get())
        }
        usvg::Paint::Pattern(_) => return None,
    };
    let alpha = (opacity * 255.0).round() as u32;
    Some(u32::from_be_bytes([color.red, color.green, color.blue, 0]) | alpha)
}

/// An SVG drawn at `scale` pixels per SVG unit, or smaller to fit `max_width` pixels.
fn draw(svg: &str, scale: f32, max_width: u32) -> Result<tiny_skia::Pixmap, RenderError> {
    let invalid = |message: String| RenderError::Invalid { message };
    let tree = parse(svg)?;
    let scale = scale.min(max_width as f32 / tree.size().width());
    let (width, height) = (
        ((tree.size().width() * scale).ceil() as u32).min(max_width),
        (tree.size().height() * scale).ceil() as u32,
    );
    if width.saturating_mul(height) > MAX_PIXELS {
        return Err(invalid("the picture is over 16 megapixels".into()));
    }
    let mut pixmap = tiny_skia::Pixmap::new(width, height)
        .ok_or_else(|| invalid("the picture is empty".into()))?;
    resvg::render(
        &tree,
        tiny_skia::Transform::from_scale(scale, scale),
        &mut pixmap.as_mut(),
    );
    Ok(pixmap)
}

/// A formula at `size` points in `color` (0xRRGGBBAA), as outlines that sit on a line of text.
#[uniffi::export]
pub fn draw_math(tex: String, size: f32, color: u32) -> Result<Drawing, RenderError> {
    if tex.len() > MAX_SOURCE {
        return Err(RenderError::TooLarge);
    }
    LazyLock::force(&MATH_FONTS);
    within_budget(BUDGET, move || math_outlines(&tex, size, color))
}

fn math_outlines(tex: &str, size: f32, color: u32) -> Result<Drawing, String> {
    let list = typeset(tex, color)?;
    let options = ratex_svg::SvgOptions {
        font_size: f64::from(size),
        padding: 0.0,
        embed_glyphs: true,
        ..Default::default()
    };
    let svg = ratex_svg::render_to_svg(&list, &options);
    let tree =
        usvg::Tree::from_str(&svg, &usvg::Options::default()).map_err(|error| error.to_string())?;
    Ok(outlines(
        &tree,
        list.width as f32 * size,
        list.total_height() as f32 * size,
        list.depth as f32 * size,
    ))
}

fn typeset(tex: &str, color: u32) -> Result<DisplayList, String> {
    let [r, g, b, a] = color
        .to_be_bytes()
        .map(|channel| f32::from(channel) / 255.0);
    let nodes = ratex_parser::parser::parse(tex).map_err(|error| error.to_string())?;
    let layout = ratex_layout::layout(
        &nodes,
        &LayoutOptions::default().with_color(Color { r, g, b, a }),
    );
    ratex_layout::validate_layout(&layout)?;
    Ok(ratex_layout::to_display_list(&layout))
}

/// A PNG of math at `size` points, `scale` pixels per point, in `color` (0xRRGGBBAA).
fn render_math(tex: String, size: f32, scale: f32, color: u32) -> Result<Vec<u8>, RenderError> {
    if tex.len() > MAX_SOURCE {
        return Err(RenderError::TooLarge);
    }
    LazyLock::force(&MATH_FONTS);
    within_budget(BUDGET, move || {
        let list = typeset(&tex, color)?;
        let options = ratex_render::RenderOptions {
            font_size: size,
            padding: 0.0,
            background_color: Color {
                r: 0.0,
                g: 0.0,
                b: 0.0,
                a: 0.0,
            },
            font_dir: String::new(),
            device_pixel_ratio: scale,
        };
        ratex_render::render_to_png(&list, &options)
    })
}

/// A standalone HTML page of `text`: `css` inlined, images under `folder` inlined, diagrams as SVG and math as PNG
/// images at twice the resolution of `math_size` points. Given `dark` colors, each diagram and formula carries a second
/// picture for a dark page; without them a diagram is inline SVG. A diagram or formula that fails shows its source.
/// Fenced code is colored in the syntaxes at `syntaxes` when they load.
#[uniffi::export]
#[allow(clippy::too_many_arguments)]
pub fn export_html(
    text: String,
    title: String,
    css: String,
    folder: Option<String>,
    colors: DiagramColors,
    dark: Option<DiagramColors>,
    math_size: f32,
    syntaxes: Option<String>,
) -> Result<String, Panicked> {
    contained(|| {
        let syntaxes = syntaxes
            .and_then(|dump| dewline_core::highlight::Syntaxes::load(std::path::Path::new(&dump)));
        let svg = |source: &str, colors: DiagramColors| {
            let svg = render_mermaid(source.to_owned(), colors).ok()?;
            Some(svg[svg.find("<svg")?..].to_owned())
        };
        let diagram = |source: &str| {
            let light = svg(source, colors)?;
            let Some(dark) = dark else { return Some(light) };
            let data = |svg: &str| {
                format!(
                    "data:image/svg+xml;base64,{}",
                    export::base64(svg.as_bytes())
                )
            };
            Some(picture(
                &data(&light),
                svg(source, dark).map(|svg| data(&svg)),
                "<img alt=\"diagram\"",
            ))
        };
        let math = |tex: &str, display: bool| {
            let size = if display { math_size * 1.2 } else { math_size };
            let png = |color: u32| render_math(tex.to_owned(), size, 2.0, color).ok();
            let light = png(colors.ink)?;
            let width = u32::from_be_bytes(light.get(16..20)?.try_into().ok()?) as f32 / 2.0;
            let data = |png: Vec<u8>| format!("data:image/png;base64,{}", export::base64(&png));
            let img = format!(
                "<img class=\"math\" alt=\"{}\" style=\"width:{width}px\"",
                export::escape(tex)
            );
            Some(picture(
                &data(light),
                dark.and_then(|dark| png(dark.ink)).map(data),
                &img,
            ))
        };
        export::html(
            &text,
            &export::ExportOptions {
                title: &title,
                css: &css,
                diagram: &diagram,
                math: &math,
                code: &|language, code| syntaxes.as_ref()?.html(language, code),
                folder: folder.as_deref().map(std::path::Path::new),
            },
        )
    })
}

/// `text` as an EPUB 3 book of the page `export_html` writes in `colors` alone, its images, diagrams and math as files
/// in the book.
#[uniffi::export]
pub fn export_epub(
    text: String,
    title: String,
    css: String,
    folder: Option<String>,
    colors: DiagramColors,
    math_size: f32,
) -> Result<Vec<u8>, docx::ExportError> {
    let page = export_html(
        text,
        title.clone(),
        css,
        folder,
        colors,
        None,
        math_size,
        None,
    )
    .map_err(|error| docx::ExportError::Io {
        message: error.to_string(),
    })?;
    contained(|| export::epub::epub(&page, &title, SystemTime::now()))
        .map_err(|error| error.to_string())
        .and_then(|book| book.map_err(|error| error.to_string()))
        .map_err(|message| docx::ExportError::Io { message })
}

/// A file an export writes beside its main file, at `path` relative to that file's folder.
#[derive(uniffi::Record)]
pub struct ExportFile {
    pub path: String,
    pub bytes: Vec<u8>,
}

/// An export's text and the files it writes beside it.
#[derive(uniffi::Record)]
pub struct TextWithFiles {
    pub text: String,
    pub files: Vec<ExportFile>,
}

impl TextWithFiles {
    fn new((text, files): (String, Vec<(String, Vec<u8>)>)) -> Self {
        TextWithFiles {
            text,
            files: files
                .into_iter()
                .map(|(path, bytes)| ExportFile { path, bytes })
                .collect(),
        }
    }
}

/// `text` as a LaTeX article named `name`, with images read from inside `folder` and diagrams drawn in `colors` as
/// PNGs at three pixels per point, at most 2400 pixels wide.
#[uniffi::export]
pub fn export_latex(
    text: String,
    name: String,
    folder: Option<String>,
    colors: DiagramColors,
) -> Result<TextWithFiles, Panicked> {
    contained(|| {
        let diagram = |source: &str| {
            let svg = render_mermaid(source.to_owned(), colors).ok()?;
            draw(&svg, 3.0, 2400).ok()?.encode_png().ok()
        };
        TextWithFiles::new(export::latex::latex(
            &text,
            &name,
            folder.as_deref().map(std::path::Path::new),
            &diagram,
        ))
    })
}

/// `text`, a note in `folder`, as portable Markdown named `name`, with the images it copies beside it.
#[uniffi::export]
pub fn export_portable_markdown(
    text: String,
    name: String,
    folder: Option<String>,
) -> Result<TextWithFiles, Panicked> {
    contained(|| {
        TextWithFiles::new(export::portable::portable(
            &text,
            &name,
            folder.as_deref().map(std::path::Path::new),
        ))
    })
}

/// `img` (an open tag without its source) showing `light`, or `dark` on a dark page.
fn picture(light: &str, dark: Option<String>, img: &str) -> String {
    match dark {
        Some(dark) => format!(
            "<picture><source media=\"(prefers-color-scheme: dark)\" srcset=\"{dark}\">{img} src=\"{light}\"></picture>"
        ),
        None => format!("{img} src=\"{light}\">"),
    }
}

/// A panic in an export that has no error of its own. Returned, it throws in Swift; UniFFI traps on a panic from an
/// export that cannot return an error.
#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum Panicked {
    #[error("{message}")]
    Panic { message: String },
}

/// `work`'s result, or its panic with the panic's message.
fn contained<T>(work: impl FnOnce() -> T) -> Result<T, Panicked> {
    panic::catch_unwind(AssertUnwindSafe(work)).map_err(|panic| Panicked::Panic {
        message: panic
            .downcast_ref::<&str>()
            .map(|message| message.to_string())
            .or_else(|| panic.downcast_ref::<String>().cloned())
            .unwrap_or_default(),
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Once;

    // mermaid-rs-renderer copies a font into XDG_CACHE_HOME, or ~/.cache without it.
    fn isolate() {
        static ONCE: Once = Once::new();
        // SAFETY: every test calls this first, so no test thread reads the environment meanwhile.
        ONCE.call_once(|| unsafe {
            std::env::set_var(
                "XDG_CACHE_HOME",
                std::env::temp_dir().join("dewline-ffi-tests"),
            );
        });
    }

    // Nightwatch, dark.
    fn night() -> DiagramColors {
        DiagramColors {
            paper: 0x08101aff,
            ink: 0xd1e1e9ff,
            ink2: 0xa3b8c5ff,
            accent: 0x62bbf5ff,
            fill: 0x0f1926ff,
        }
    }

    #[test]
    fn edge_labels_move_off_the_node_their_edge_enters() {
        isolate();
        let svg = mermaid_within(
            Duration::from_secs(30),
            "flowchart LR\n  E[POST /v1/events] --> Q[(deliveries)]\n  Q --> W[Worker]\n  W -->|2xx| D[delivered]\n  \
             W -->|5xx or timeout| B[Backoff]\n  B --> Q\n  W -->|attempt 12| P[parked]"
                .into(),
            night(),
        )
        .unwrap();
        // The x and width of the rect just before `text`, or of the edge label rect named `edge`.
        let number = |tag: &str, name: &str| -> f32 {
            let start = tag.find(&format!(" {name}=\"")).unwrap() + name.len() + 3;
            tag[start..start + tag[start..].find('"').unwrap()]
                .parse()
                .unwrap()
        };
        let backoff = &svg[..svg.find(">Backoff<").unwrap()];
        let node = &backoff[backoff.rfind("<rect ").unwrap()..];
        let label = &svg[svg.find("<rect data-edge-id=\"edge-3\"").unwrap()..];
        assert!(
            number(label, "x") >= number(node, "x") + number(node, "width"),
            "{svg}"
        );
    }

    #[test]
    fn mermaid_renders_svg() {
        isolate();
        let svg = render_mermaid("flowchart LR\n  a[Start] --> b[Stop]".into(), night()).unwrap();
        assert!(svg.starts_with("<svg") && svg.contains("Start"));
    }

    #[test]
    fn mermaid_folds_a_long_flow_into_the_column() {
        isolate();
        // Folding, not speed, is under test; a shared runner can overrun the production budget.
        let svg = mermaid_within(
            Duration::from_secs(30),
            "flowchart LR\n  a[Write the draft] --> b[Agent edits] --> c[Review changes] --> d[Keep or revert] --> e[Save]".into(),
            night(),
        )
        .unwrap();
        let tree = usvg::Tree::from_str(&svg, &usvg::Options::default()).unwrap();
        assert!(tree.size().width() <= COLUMN * Theme::modern().font_size / LEAST_LABEL);
    }

    #[test]
    fn mermaid_takes_the_theme_colors() {
        isolate();
        let svg = render_mermaid(
            "sequenceDiagram\n  a->>b: hi\n  note over b: n".into(),
            night(),
        )
        .unwrap();
        for color in [
            "#08101aff",
            "#d1e1e9ff",
            "#a3b8c5ff",
            "#62bbf5ff",
            "#0f1926ff",
        ] {
            assert!(svg.contains(color), "{color} is missing");
        }
    }

    #[test]
    fn light_only_kinds_keep_the_light_theme_on_a_dark_page() {
        isolate();
        let svg = render_mermaid("timeline\n  2002 : LinkedIn".into(), night()).unwrap();
        assert!(svg.contains("fill=\"#FFFFFF\"") && !svg.contains("#08101aff"));
    }

    #[test]
    fn mermaid_errors_name_the_problem() {
        isolate();
        let Err(RenderError::Invalid { message }) =
            render_mermaid("venn-beta\n  set A\n  set B".into(), night())
        else {
            panic!("rendered a diagram type the renderer does not parse");
        };
        assert_eq!(message, "unsupported diagram type 'venn'");
        let Err(RenderError::Invalid { message }) = render_mermaid(
            "---\ntitle: T\n---\nclassDiagram\n  class A {\n    <<interface>>\n  }".into(),
            night(),
        ) else {
            panic!("rendered a class body the renderer does not parse");
        };
        assert!(message.contains("<<interface>>"), "{message}");
        assert!(matches!(
            render_mermaid("%%\n".repeat(MAX_SOURCE), night()),
            Err(RenderError::TooLarge)
        ));
    }

    #[test]
    fn svg_becomes_outlines_in_points() {
        isolate();
        let svg = r#"<svg xmlns="http://www.w3.org/2000/svg" width="10" height="4"><rect width="10" height="4" fill="red" fill-opacity="0.5"/><path d="M0 2H10" fill="none" stroke="blue"/></svg>"#;
        let drawing = outlines(&parse(svg).unwrap(), 10.0, 4.0, 0.0);
        assert_eq!(
            (drawing.width, drawing.height, drawing.shapes.len()),
            (10.0, 4.0, 2)
        );
        let [rect, line] = &drawing.shapes[..] else {
            unreachable!()
        };
        assert_eq!((rect.color, line.color), (0xff000080, 0x0000ffff));
        assert_eq!(rect.verbs, [0, 1, 1, 1, 4]);
        assert_eq!(rect.points[..4], [0.0, 0.0, 10.0, 0.0]);
        let ys = line.points.iter().skip(1).step_by(2);
        assert!(ys.clone().all(|y| (1.5..=2.5).contains(y)) && ys.clone().any(|y| *y < 2.0));
    }

    #[test]
    fn math_draws_outlines_on_its_baseline() {
        isolate();
        let drawing = draw_math(r"\frac{a}{b}".into(), 20.0, 0x112233ff).unwrap();
        assert!(drawing.depth > 0.0 && drawing.height > drawing.depth && drawing.width > 0.0);
        assert!(
            !drawing.shapes.is_empty()
                && drawing.shapes.iter().all(|shape| shape.color == 0x112233ff)
        );
        assert!(
            drawing
                .shapes
                .iter()
                .flat_map(|shape| shape.points.chunks(2))
                .all(|point| {
                    (-0.5..=drawing.width + 0.5).contains(&point[0])
                        && (-0.5..=drawing.height + 0.5).contains(&point[1])
                })
        );
    }

    #[test]
    fn diagrams_draw_their_labels_as_outlines() {
        isolate();
        let drawing = draw_mermaid("flowchart LR\n  a[Start] --> b[Stop]".into(), night()).unwrap();
        let labels: Vec<_> = drawing
            .shapes
            .iter()
            .filter(|shape| shape.color == night().ink)
            .collect();
        assert!(
            labels.len() == 2 && labels.iter().all(|label| label.verbs.len() > 20),
            "each label's letters are outlines in the ink"
        );
        assert!(
            drawing
                .shapes
                .iter()
                .any(|shape| shape.color == night().ink2)
        );
    }

    #[test]
    fn math_renders_png_or_names_the_error() {
        isolate();
        let png = render_math(r"\frac{a}{b}".into(), 17.0, 2.0, 0x000000ff).unwrap();
        assert_eq!(png[1..4], *b"PNG");
        assert!(matches!(
            render_math(r"\frac{a".into(), 17.0, 2.0, 0x000000ff),
            Err(RenderError::Invalid { .. })
        ));
    }

    #[test]
    fn math_over_the_size_cap_is_refused() {
        isolate();
        assert!(matches!(
            render_math("%\n".repeat(MAX_SOURCE), 17.0, 2.0, 0x000000ff),
            Err(RenderError::TooLarge)
        ));
    }

    #[test]
    fn books_and_articles_carry_their_diagrams_as_files() {
        isolate();
        let text = "# Notes\n\n$x^2$\n\n```mermaid\nflowchart LR\n  a[Start] --> b\n```\n";
        let book =
            export_epub(text.into(), "t".into(), String::new(), None, night(), 17.0).unwrap();
        let book = String::from_utf8_lossy(&book);
        assert!(
            book.contains("OEBPS/images/image-1.png")
                && book.contains("OEBPS/images/diagram-2.svg")
        );
        let article = export_latex(text.into(), "notes".into(), None, night()).unwrap();
        assert!(
            article.text.contains("$x^2$") && article.text.contains("{notes-files/diagram-1.png}")
        );
        assert_eq!(article.files.len(), 1);
        assert!(article.files[0].bytes.starts_with(b"\x89PNG\r\n\x1a\n"));
    }

    #[test]
    fn export_embeds_diagrams_and_math_in_each_palette() {
        isolate();
        let text = "$x^2$\n\n```mermaid\nflowchart LR\n  a[Start] --> b\n```\n";
        let page = export_html(
            text.into(),
            "t".into(),
            String::new(),
            None,
            night(),
            None,
            17.0,
            None,
        )
        .unwrap();
        assert!(
            page.contains("<figure class=\"diagram\"><svg") && page.contains("Start"),
            "{page}"
        );
        assert!(
            page.contains("<img class=\"math\" alt=\"x^2\" style=\"width:"),
            "{page}"
        );
        assert!(
            page.contains("src=\"data:image/png;base64,iVBORw0KGgo"),
            "{page}"
        );
        assert!(!page.contains("<picture>"), "{page}");
        let both = export_html(
            text.into(),
            "t".into(),
            String::new(),
            None,
            night(),
            Some(night()),
            17.0,
            None,
        )
        .unwrap();
        assert_eq!(
            both.matches(
                "<picture><source media=\"(prefers-color-scheme: dark)\" srcset=\"data:image/"
            )
            .count(),
            2,
            "{both}"
        );
    }
}
