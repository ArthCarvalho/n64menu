#include <stdio.h>

#include <libcart/cart.h>
#include <libdragon.h>

#include "boot/boot.h"
#include "flashcart/flashcart.h"
#include "flashcart/sc64/sc64_ll.h"
#include "utils/fs.h"

#define PI 3.141592653f
#define PI2 (PI*2.0f)

#define RDPQ_COMBINER_TEX_ALPHA   RDPQ_COMBINER1((0,0,0,PRIM),    (TEX0,0,PRIM,0))

int menu_active;
boot_params_t boot_params;
char rom_path[1024];

// sc64_init() leaves the boot mode at BOOT_MODE_MENU and nothing in the menu
// changes it, so a switch to BOOT_MODE_ROM means sc64deployer has just written a
// ROM into cartridge SDRAM over USB. Booting it here removes the manual reset
// from the development loop; the SD card stays locked to the console throughout.
void usb_upload_poll(void) {
    static int countdown = 30;
    uint32_t mode;

    if(cart_type != CART_SC) return;
    if(--countdown > 0) return;
    countdown = 30;

    if(sc64_ll_get_config(CFG_ID_BOOT_MODE, &mode) != SC64_OK) return;
    if(mode != BOOT_MODE_ROM) return;

    boot_params.device_type = BOOT_DEVICE_TYPE_ROM;
    boot_params.tv_type = BOOT_TV_TYPE_PASSTHROUGH;
    boot_params.detect_cic_seed = true;
    menu_active = false;
}

float lerp(float t, float a, float b) {
    return a + (b - a) * t;
}

float bezier_interp(float t, float x1, float y1, float x2, float y2) {
    float f0 = 1.0f - 3.0f * x2 + 3 * x1;
    float f1 = 3.0f * x2 - 6.0f * x1;
    float f2 = 3.0f * x1;
    float refinedT = t;

    for (int i = 0; i < 5; i++) {
        float refinedT2 = refinedT * refinedT;
        float refinedT3 = refinedT2 * refinedT;

        float x = f0 * refinedT3 + f1 * refinedT2 + f2 * refinedT;
        float slope = 1.0f / (3.0f * f0 * refinedT2 + 2.0f * f1 * refinedT + f2);
        refinedT -= (x - t) * slope;
        if(refinedT < 0.0f) refinedT = 0.0f;
        if(refinedT > 1.0f) refinedT = 1.0f;
    }

    // Resolve cubic bezier for the given x
    return 3.0f * pow(1.0f - refinedT, 2.0f) * refinedT * y1 + 3.0f * (1.0f - refinedT) * pow(refinedT, 2.0f) * y2 + pow(refinedT, 3.0f);
}

sprite_t *logo_header;
sprite_t *logo_splash;
sprite_t *logo_header_inner;
sprite_t *logo_splash_inner;

rdpq_font_t *font_body;
rdpq_font_t *font_title;
rdpq_font_t *font_small;
rdpq_font_t *font_cap;

#define FONT_BODY    1
#define FONT_TITLE   2
#define FONT_SMALL   3
#define FONT_CAP     4

#define STYLE_WHITE      0
#define STYLE_YELLOW     1
#define STYLE_DIM        2
#define STYLE_GREY       3
#define STYLE_SHADOW     4
#define STYLE_OUTLINE    5
#define STYLE_SHADOW_SEL 6

int spinner_fade_counter = 0;
float spinner_fade = 0.0f;
float spinner_counter = 0.0f;

void spinner_draw(float x, float y, float size, float alpha) {
    float dot_size = 4.0f;
    for(int a = 11; a >= 0 ; a--) {
        float thisAnimSize = (12.0f - fmod((spinner_counter + a),12.0f))- 9.0f;
        if(thisAnimSize < 0.0f) thisAnimSize = 0.0f;
        float animParam = thisAnimSize / 3.0f;
        float scaled = 0.4f + (animParam * 0.6f);
        float dot_ang = (a / 12.0f) * PI2;
        float dot_x = (x + sin(dot_ang) * size) - dot_size * scaled;
        float dot_y = (y + cos(dot_ang) * size) - dot_size * scaled;
        int intensity = alpha * (90 + animParam * 165.0f);
        rdpq_set_mode_fill(RGBA32(255, 204, 0, intensity));
        rdpq_fill_rectangle(dot_x, dot_y, dot_x + dot_size * scaled * 2.0f, dot_y + dot_size * scaled * 2.0f);
    }
    spinner_counter += 0.25f;
}
        
static void cart_load_progress(float progress) {
    surface_t *d = (progress >= 1.0f) ? display_get() : display_try_get();
    if (d) {
        rdpq_attach(d, NULL);

        rdpq_set_mode_fill(RGBA32(0,0,0,0));
        rdpq_fill_rectangle(0, 0, 640, 480);

        rdpq_set_mode_standard();
        spinner_fade_counter++;
        if(spinner_fade_counter >= 10) {
            spinner_fade = (spinner_fade_counter - 10) / 30.0f;
            if(spinner_fade > 1.0f) spinner_fade = 1.0f;
            spinner_draw(640 - 55, 480 - 48, 20, spinner_fade);
        }
        rdpq_detach_show();
    }
    
}

float fade_v1[] = { 0, 0 };
float fade_v2[] = { 640, 480 };
float fade_v3[] = { 0, 480 };
float fade_v4[] = { 640, 0 };

joypad_buttons_t p1_buttons;
joypad_buttons_t p1_buttons_press;
joypad_inputs_t p1_inputs;

#define SCREEN_WIDTH 640
#define SCREEN_HEIGHT 480

#define CURSOR_INTERVAL 25
#define CURSOR_INTERVAL_SECOND (CURSOR_INTERVAL - 6)

#define FADE_DURATION 60.0f
#define OPENING_WAIT 60.0f * 2.0f
#define OPENING_SOUND_PLAY (OPENING_WAIT - 10.0f)
#define OPENING_OUT 20.0f

#define SCR_REGION_X_MIN 16.0f
#define BOX_REGION_X_MIN 64.0f
#define BOX_REGION_X_MAX 608.0f
#define BOX_REGION_Y_MIN 120.0f
#define BOX_REGION_Y_MAX 413.0f

// M64 leans on negative space: covers get real gutters instead of NSO's flush packing.
#define GRID_GUTTER 16.0f
#define GRID_SCISSOR_X_MIN (BOX_REGION_X_MIN - 48.0f)
#define GRID_SCISSOR_X_MAX (BOX_REGION_X_MAX + 16.0f)
#define GRID_SCISSOR_Y_MIN (BOX_REGION_Y_MIN - 4.0f)
#define GRID_SCISSOR_Y_MAX (BOX_REGION_Y_MAX + 4.0f)
#define CHROME_RULE_Y 62.0f
#define HINT_Y 444.0f

#define TITLE_BOX_WIDTH_E 256.0f
#define TITLE_BOX_HEIGHT_E 179.0f

#define TITLE_BOX_WIDTH_BORDER_E 257.0f
#define TITLE_BOX_HEIGHT_BORDER_W 180.0f

#define TITLE_SELECT_SCALE 1.2f

#define CHANNEL_SFX1    0
#define CHANNEL_SFX2    2
#define CHANNEL_SFX3    4
#define CHANNEL_MUSIC   6

float box_region_min_x = BOX_REGION_X_MIN;
float box_region_max_x = BOX_REGION_X_MAX;
float box_region_min_y = BOX_REGION_Y_MIN;
float box_region_max_y = BOX_REGION_Y_MAX;

float viewport_y = BOX_REGION_Y_MIN;
float viewport_y_bottom = BOX_REGION_Y_MAX;
float viewport_y_target = BOX_REGION_Y_MIN;

float box_region_scissor_left = 64.0f;

int fade_state = 0;
int fade_counter = FADE_DURATION;
float fade_lvl = 1.0f;

int main_state = 0;
int opening_counter = OPENING_WAIT;
float opening_card_offset_x = 0.0f;

// Sliding five-row library window reflected by the header ribbon.
int library_position_segment = 0;
int library_row_window_start = 0;
int library_populated_rows = 0;
char library_row_initial[50] = {0};

char title_initial_normalize(char c) {
    if(c >= 'a' && c <= 'z') return c - ('a' - 'A');
    if((c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9')) return c;
    return 0;
}

char title_initial_load(char * id) {
    char path[128];
    char c;

    // New imports preserve the filename as display metadata.
    snprintf(path, sizeof(path), "sd:/menu/title/%s/%s_e.name", id, id);
    FILE * f = fopen(path, "r");
    if(f != NULL) {
        while(fread(&c, 1, 1, f) == 1) {
            char initial = title_initial_normalize(c);
            if(initial != 0) {
                fclose(f);
                return initial;
            }
        }
        fclose(f);
    }

    // Existing cards have no name sidecar, so use the internal ROM title.
    snprintf(path, sizeof(path), "sd:/menu/title/%s/%s_e.z64", id, id);
    f = fopen(path, "rb");
    if(f != NULL) {
        if(fseek(f, 0x20, SEEK_SET) == 0) {
            for(int i = 0; i < 20 && fread(&c, 1, 1, f) == 1; i++) {
                char initial = title_initial_normalize(c);
                if(initial != 0) {
                    fclose(f);
                    return initial;
                }
            }
        }
        fclose(f);
    }

    return title_initial_normalize(id[0]);
}

void outline_draw(float x, float y, float width, float height, int size, color_t color) {
    x = round(x);
    y = round(y);
    width = ceil(width);
    height = ceil(height);
    rdpq_set_mode_fill(color);
    rdpq_fill_rectangle(x, y, x + width, y + size);
    rdpq_fill_rectangle(x, y + height - size, x + width, y + height);
    rdpq_fill_rectangle(x, y, x + size, y + height);
    rdpq_fill_rectangle(x + width - size, y, x + width, y + height);
}

void quad_draw(float x1, float y1, float x2, float y2, float skew, color_t color) {
    rdpq_set_mode_fill(color);
    rdpq_triangle(&TRIFMT_FILL,
        (float[]){ x1 + skew, y1 }, (float[]){ x2, y1 }, (float[]){ x1, y2 });
    rdpq_triangle(&TRIFMT_FILL,
        (float[]){ x2, y1 }, (float[]){ x2 - skew, y2 }, (float[]){ x1, y2 });
}

void disc_draw(float cx, float cy, int radius, color_t color) {
    rdpq_set_mode_fill(color);
    for(int y = -radius; y <= radius; y++) {
        int half_width = sqrt(radius * radius - y * y);
        rdpq_fill_rectangle(cx - half_width, cy + y, cx + half_width + 1, cy + y + 1);
    }
}

// Layered circular button cap: shadow, body, and a small top-left highlight.
// Unlike the old two-rectangle octagon, the silhouette stays round at this size.
// Sized against the console's own legend measured in the same frame, with its
// overlay open so both legends sat at one scale: theirs is 38 capture pixels
// across, so the radius is 8 for 17 framebuffer pixels rather than the 21 that
// an earlier reading off separate captures produced.
void button_cap_draw(float cx, float cy, color_t dark, color_t color, color_t light) {
    disc_draw(cx + 1, cy + 1, 8, RGBA32(0, 0, 0, 255));
    disc_draw(cx, cy, 8, dark);
    disc_draw(cx, cy - 1, 6, color);
    disc_draw(cx - 2, cy - 3, 2, light);
}

// Centred through the layout engine rather than by hand, then nudged by the
// residual measured off a capture: the glyph box centres the advance width, which
// leaves the inked shape slightly high and left of the cap.
//
// Drawn at 8pt rather than the 12pt used elsewhere. At 12pt the letter filled most
// of the inner disc, where the console leaves clear colour around it on all sides.
// Press Start 2P ships regular only, so the weight comes from overdrawing a second
// pass one pixel across: the console's letter is heavier than a single pass gives,
// and thickening by hand keeps it a font rather than a hand-built glyph.
void button_letter_draw(float cx, float cy, const char *label) {
    const float box = 14.0f;
    for(int dx = 0; dx <= 1; dx++) {
        rdpq_text_print(&(rdpq_textparms_t){
            .width = box, .height = box,
            .align = ALIGN_CENTER, .valign = VALIGN_CENTER,
        }, FONT_CAP, cx - box * 0.5f + dx + 0.5f, cy - box * 0.5f + 2.0f, label);
    }
}

// M64 marks the active row with a solid yellow triangle, not a highlighted card.
void marker_draw(float x, float y, float size, color_t color) {
    rdpq_set_mode_fill(color);
    rdpq_triangle(&TRIFMT_FILL,
        (float[]){ x, y }, (float[]){ x + size, y + size * 0.5f }, (float[]){ x, y + size });
}

void focus_draw(float x, float y, float width, float height) {
    // Thin yellow hairline frame; the emphasis comes from brightness + marker, not chrome.
    outline_draw(x, y, width, height, 2, RGBA32(255, 214, 0, 255));
    marker_draw(x - 14, y + height * 0.5f - 7, 11, RGBA32(255, 214, 0, 255));
}

// The M64 mark is layered yellow -> orange -> pink rather than a flat tint. The
// sprite is a white mask, so we blit it once per horizontal band, clipped by scissor.
//
// Drawn at an exact 2x with point sampling: the sprite is generated on half the
// grid so each texel lands as a clean square block, matching how coarse the
// console's own mark is. An integer factor keeps every block the same size.
#define LOGO_SCALE 2.0f

void logo_draw(sprite_t *logo, sprite_t *inner, float x, float y) {
    if(logo == NULL || logo->width <= 0 || logo->width > 512 ||
       logo->height <= 0 || logo->height > 256 || inner == NULL ||
       inner->width != logo->width || inner->height != logo->height) return;

    float w = logo->width * LOGO_SCALE;
    float h = logo->height * LOGO_SCALE;

    const float band_top[3] = { 0.00f, 0.44f, 0.74f };
    const float band_bot[3] = { 0.44f, 0.74f, 1.00f };
    color_t band_col[3] = {
        RGBA32(255, 214, 0, 255),
        RGBA32(255, 122, 0, 255),
        RGBA32(255, 35, 156, 255),
    };
    color_t edge_col[3] = {
        RGBA32(206, 166, 0, 255),
        RGBA32(208, 88, 0, 255),
        RGBA32(205, 18, 116, 255),
    };

    rdpq_set_mode_standard();
    // Blitted at an exact scale, so sampling must be point: bilinear averages
    // neighbouring texels and erases single-pixel detail such as the counter
    // inside the 6.
    rdpq_mode_filter(FILTER_POINT);
    rdpq_mode_combiner(RDPQ_COMBINER_TEX_FLAT);
    // Drop the uncovered texels rather than drawing them black. Without this the
    // blit lays down an opaque quad, so offset copies square each other off and no
    // outline survives. The sprites are decimated to a hard one-bit edge, so a
    // threshold compare is enough and costs no blending.
    rdpq_mode_alphacompare(1);

    // Keyline first, one source pixel thick, so the bands land on top of it and
    // leave only the outline showing. The reference carries one because its mark
    // sits over game content, where an unoutlined shape loses its edges.
    rdpq_set_scissor(0, 0, SCREEN_WIDTH, SCREEN_HEIGHT);
    rdpq_set_prim_color(RGBA32(0, 0, 0, 255));
    static const float key_x[8] = { -1.0f, 1.0f,  0.0f, 0.0f, -1.0f, 1.0f, -1.0f, 1.0f };
    static const float key_y[8] = {  0.0f, 0.0f, -1.0f, 1.0f, -1.0f, -1.0f, 1.0f, 1.0f };
    for(int k = 0; k < 8; k++) {
        rdpq_sprite_blit(logo, x + key_x[k] * LOGO_SCALE, y + key_y[k] * LOGO_SCALE,
            &(rdpq_blitparms_t){ .scale_x = LOGO_SCALE, .scale_y = LOGO_SCALE });
    }

    for(int i = 0; i < 3; i++) {
        // The splash slides the mark off-screen, so the band rect must be clamped
        // to the framebuffer: rdpq_set_scissor rejects negative coordinates.
        float sx0 = x;
        float sx1 = x + w + 2;
        float sy0 = y + h * band_top[i];
        float sy1 = y + h * band_bot[i];

        if(sx0 < 0.0f) sx0 = 0.0f;
        if(sy0 < 0.0f) sy0 = 0.0f;
        if(sx1 > SCREEN_WIDTH) sx1 = SCREEN_WIDTH;
        if(sy1 > SCREEN_HEIGHT) sy1 = SCREEN_HEIGHT;
        if(sx1 <= sx0 || sy1 <= sy0) continue;

        rdpq_set_scissor(sx0, sy0, sx1, sy1);
        // The full silhouette goes down dark first. The eroded mask then replaces
        // its interior with the normal colour, leaving one source texel of shading
        // immediately inside the black keyline. Point sampling keeps that fringe
        // as discrete squares instead of softening the whole mark.
        rdpq_set_prim_color(edge_col[i]);
        rdpq_sprite_blit(logo, x, y, &(rdpq_blitparms_t){
            .scale_x = LOGO_SCALE, .scale_y = LOGO_SCALE,
        });
        rdpq_set_prim_color(band_col[i]);
        rdpq_sprite_blit(inner, x, y, &(rdpq_blitparms_t){
            .scale_x = LOGO_SCALE, .scale_y = LOGO_SCALE,
        });
    }

    rdpq_set_scissor(0, 0, SCREEN_WIDTH, SCREEN_HEIGHT);
}

// The tabs are the mark's slashes reused as navigation, so their lean is taken
// from the supplied logo artwork (dx/dy = 1.0, measured from the asset). Slant is applied
// per height rather than as a fixed offset, otherwise tabs of different depths
// would end up at different angles.
#define RIBBON_SLANT     1.0f
#define RIBBON_Y0        14.0f
#define RIBBON_LEAD_H    44.0f          // tabs before the selection
#define RIBBON_FULL_H    50.0f          // selection and the tabs behind it
#define RIBBON_GLYPH_W   40.0f
#define RIBBON_GAP       4.0f
#define RIBBON_STEP      (RIBBON_GLYPH_W + RIBBON_GAP)
#define RIBBON_T0        404.0f         // top-left of the first tab
#define RIBBON_RULE_TOP  61.0f
#define RIBBON_RULE_BOT  64.0f

// Anchored on the tab's top-left corner so every tab tiles from the same edge
// regardless of how deep it runs.
void ribbon_tab(float top_x, float height, color_t color) {
    float skew = height * RIBBON_SLANT;
    quad_draw(top_x - skew, RIBBON_Y0, top_x + RIBBON_GLYPH_W,
        RIBBON_Y0 + height, skew, color);
}

void ribbon_draw(void) {
    color_t inactive[2] = {
        RGBA32(74, 32, 122, 255),
        RGBA32(113, 48, 183, 255),
    };
    color_t pink = RGBA32(255, 35, 156, 255);

    int tab_count = library_populated_rows < 5 ? library_populated_rows : 5;
    if(tab_count < 1) tab_count = 1;

    float selected_x = RIBBON_T0 + library_position_segment * RIBBON_STEP;
    float skew_full = RIBBON_FULL_H * RIBBON_SLANT;
    float skew_rule = (RIBBON_RULE_BOT - RIBBON_RULE_TOP) * RIBBON_SLANT;

    // The baseline is the ribbon's lower edge. Its right end is slanted so it
    // meets the selection's edge instead of protruding past it.
    float rule_end = selected_x + RIBBON_GLYPH_W - skew_full;
    quad_draw(BOX_REGION_X_MIN - skew_rule, RIBBON_RULE_TOP,
        rule_end + skew_rule, RIBBON_RULE_BOT, skew_rule, pink);

    // Tabs ahead of the selection stop short of the baseline, leaving a gap.
    // Tabs behind it run down to the baseline's underside, so the ribbon reads
    // as one continuous edge from the rule through the selection.
    for(int i = 0; i < tab_count; i++) {
        if(i == library_position_segment) continue;
        float top_x = RIBBON_T0 + i * RIBBON_STEP;
        float height = i < library_position_segment ? RIBBON_LEAD_H : RIBBON_FULL_H;
        ribbon_tab(top_x, height, inactive[i & 1]);
    }

    ribbon_tab(selected_x, RIBBON_FULL_H, pink);

    // Each tab names its row by the first letter of that row's first title. The
    // reference icons carry a keyline and a shadow cast along the tab, which is
    // what makes them read as standing on the plane rather than printed on it.
    for(int i = 0; i < tab_count; i++) {
        int row = library_row_window_start + i;
        char initial = library_row_initial[row] != 0 ? library_row_initial[row] : '?';

        // Sit the letter low and left on the tab. Descending the slant already
        // carries it left, so the offset is measured from the tab's midline at
        // the letter's own height rather than from its top corner.
        float x = RIBBON_T0 + i * RIBBON_STEP - 13.0f;
        float y = 47.0f;

        // A uniform offset reads as the letter hovering, or as extrusion. A real
        // shadow is anchored at the base and sweeps further the higher up the
        // glyph it is cast from, so shear it: each horizontal slice is displaced
        // in proportion to its height above the letter's feet. The throw is taken
        // from the reference icons, whose shadows reach about 0.45 of their height.
        const int bands = 8;
        const float band_h = 16.0f / bands;
        for(int b = 0; b < bands; b++) {
            float band_top = y - 16.0f + b * band_h;
            float lift = 1.0f - (float)b / (float)(bands - 1);
            float ox = 1.0f + lift * 9.0f;
            float oy = lift * 4.0f;

            rdpq_set_scissor(0, band_top + oy, SCREEN_WIDTH, band_top + band_h + oy);
            rdpq_text_printf(NULL, FONT_BODY, x + ox, y + oy,
                i == library_position_segment ? "^06%c" : "^04%c", initial);
        }
        rdpq_set_scissor(0, 0, SCREEN_WIDTH, SCREEN_HEIGHT);

        static const float outline_x[4] = { -1.0f, 1.0f,  0.0f, 0.0f };
        static const float outline_y[4] = {  0.0f, 0.0f, -1.0f, 1.0f };
        for(int o = 0; o < 4; o++) {
            rdpq_text_printf(NULL, FONT_BODY, x + outline_x[o], y + outline_y[o],
                "^05%c", initial);
        }

        rdpq_text_printf(NULL, FONT_BODY, x, y,
            i == library_position_segment ? "^01%c" : "^03%c", initial);
    }
}

// Vertical ramp from deep violet to a warmer purple, laid down as bands. Kept dark
// on purpose: box art sits on top of it, and anything brighter costs the covers
// their contrast, especially the ones dimmed while unselected.
#define BG_TOP_R 16
#define BG_TOP_G 6
#define BG_TOP_B 38
#define BG_BOT_R 68
#define BG_BOT_G 18
#define BG_BOT_B 86
#define BG_BANDS 32

// The ground is a static ramp with a soft sheen sliding up it.
//
// This started as a VHS treatment with grain and dropout speckle over the bar. That
// was dropped: the console's own interface is flat colour with no texture, and the
// rest of this work goes out of its way to keep the image crisp, disabling the video
// filters, sampling sprites point and blitting at whole scales. Animated grain pulls
// against all of it, so only the movement is kept.
//
// The sheen is a stack of translucent strips that move as one rigid object. An earlier
// version animated per band brightness instead, which looked slow and jerky at the
// same time: each band's lift changed by about two units a frame, but the framebuffer
// is sixteen bit and quantises in steps of eight, so bands sat still and then popped a
// whole level, each at its own moment. Sliding a fixed shape sidesteps that entirely,
// because nothing has to change value to make it appear to move.
#define BAR_STEPS   16
#define BAR_STEP_H  5                        /* 80px tall, soft enough not to step */
#define BAR_PEAK    56                       /* alpha at the centre of the sheen */
#define BAR_PX_PER_SEC 60                    /* upward travel, independent of frame rate */
#define BAR_MARGIN  40                       /* rest off screen between passes */


void background_draw(void) {
    // Drive the motion from elapsed time, not from a frame counter. Tying it to the
    // number of draws makes the speed a function of how fast the console happens to
    // be rendering, so the same constant means different things on a loaded frame or
    // at a different clock. Milliseconds keep it fixed at so many pixels a second.
    // The multiply is done at 64 bits because the millisecond count times the speed
    // overruns 32 bits after about forty minutes of uptime.
    unsigned long long ms = (unsigned long long)get_ticks_ms();

    const int bar_h = BAR_STEPS * BAR_STEP_H;
    const int span  = SCREEN_HEIGHT + bar_h + BAR_MARGIN;

    // Static ramp underneath. Nothing here animates, so it can stay in fill mode.
    // Set the mode once and then only change the colour: rdpq_set_mode_fill resets the
    // whole pipeline state, and calling it per band cost more than the fill itself.
    rdpq_set_mode_fill(RGBA32(BG_TOP_R, BG_TOP_G, BG_TOP_B, 255));
    for(int i = 0; i < BG_BANDS; i++) {
        float t = (float)i / (float)(BG_BANDS - 1);
        uint8_t r = (uint8_t)(BG_TOP_R + (BG_BOT_R - BG_TOP_R) * t);
        uint8_t g = (uint8_t)(BG_TOP_G + (BG_BOT_G - BG_TOP_G) * t);
        uint8_t b = (uint8_t)(BG_TOP_B + (BG_BOT_B - BG_TOP_B) * t);
        int y0 = (SCREEN_HEIGHT * i) / BG_BANDS;
        // Derive the end from the next band rather than adding a height, so rounding
        // cannot leave a seam of stale framebuffer between bands.
        int y1 = (SCREEN_HEIGHT * (i + 1)) / BG_BANDS;
        rdpq_set_fill_color(RGBA32(r, g, b, 255));
        rdpq_fill_rectangle(0, y0, SCREEN_WIDTH, y1);
    }

    // Counts downward so the bar travels up the screen, the direction tape drifts.
    int travel = (int)((ms * BAR_PX_PER_SEC / 1000ULL) % (unsigned long long)span);
    int bar_y = SCREEN_HEIGHT + BAR_MARGIN - travel;

    rdpq_set_mode_standard();
    // Ordered dithering, not noise. Something has to break up the sixteen bit
    // quantisation or the bar's ramp lands in hard steps, but noise dithering
    // regenerates every frame and reads as grain. A Bayer pattern is fixed in screen
    // space, so it smooths the ramp without anything shimmering on top of it.
    rdpq_mode_dithering(DITHER_BAYER_BAYER);
    rdpq_mode_combiner(RDPQ_COMBINER_FLAT);
    rdpq_mode_blender(RDPQ_BLENDER_MULTIPLY);

    for(int i = 0; i < BAR_STEPS; i++) {
        // Triangular ramp, so the bar fades in and out rather than presenting an edge.
        int half = BAR_STEPS / 2;
        int d = (i < half) ? i : (BAR_STEPS - 1 - i);
        int a = (d * BAR_PEAK) / half;
        if(a <= 0) continue;

        int y0 = bar_y + i * BAR_STEP_H;
        int y1 = y0 + BAR_STEP_H;
        if(y1 <= 0 || y0 >= SCREEN_HEIGHT) continue;
        if(y0 < 0) y0 = 0;
        if(y1 > SCREEN_HEIGHT) y1 = SCREEN_HEIGHT;

        rdpq_set_prim_color(RGBA32(168, 132, 220, a));
        rdpq_fill_rectangle(0, y0, SCREEN_WIDTH, y1);
    }
}

void chrome_draw(void) {
    background_draw();

    ribbon_draw();

    logo_draw(logo_header, logo_header_inner, BOX_REGION_X_MIN, 8);
}


typedef struct SquareSprite_s {
    float x, y;
    float width;
    float height;
} SquareSprite;

typedef struct TitleBox_s {
    char id[8];
    sprite_t * image;
    SquareSprite sprite;
    float scale;
    float scaleGrow;
    float offset_x, offset_y;
    int isSelected;
    float selectedOutline;
    float outlineCounter;
    float screenX;
    float screenY;
} TitleBox;

float title_brightness = 1.0f;

#define MAX_TITLE_COUNT 40

int title_count = 0;

/** Set when the catalog was larger than the menu can hold, so the UI can say so. */
int title_truncated = 0;

/** Longest title ID accepted, excluding the terminator (TitleBox.id is 8 bytes). */
#define TITLE_ID_MAX 7

/** Upper bound on menu/title.csv, so a malformed card cannot exhaust memory. */
#define TITLE_CSV_MAX 1024

/** Static storage avoids disturbing the heap that owns all loaded sprites. */
static char title_csv[TITLE_CSV_MAX + 1];

TitleBox title_list[MAX_TITLE_COUNT];

#define TITLE_COLUMNS 4
#define TITLE_ROWS 50
#define TITLE_TOTAL_SLOTS (TITLE_ROWS * TITLE_COLUMNS)

TitleBox * title_row[TITLE_ROWS][TITLE_COLUMNS] = {
    {NULL, NULL, NULL, NULL},
    {NULL, NULL, NULL, NULL},
    {NULL, NULL, NULL, NULL},
    {NULL, NULL, NULL, NULL},
    {NULL, NULL, NULL, NULL},
    {NULL, NULL, NULL, NULL},
    {NULL, NULL, NULL, NULL},
    {NULL, NULL, NULL, NULL},
    {NULL, NULL, NULL, NULL},
    {NULL, NULL, NULL, NULL}
};
int title_row_count[TITLE_ROWS] = {4,4,2,0,0,0,0,0,0,0};

TitleBox * selectedTitle = NULL;

int cursor_x = 0;
int cursor_x_timer = 0;
int cursor_y = 0;
int cursor_y_timer = 0;

void TitleBox_create(TitleBox * title, sprite_t * image, float x, float y) {
    title->image = image;
    title->sprite.x = x;
    title->sprite.y = y;
    title->sprite.width = TITLE_BOX_WIDTH_E;
    title->sprite.height = TITLE_BOX_HEIGHT_E;
    title->scale = 1.0f;
    title->offset_x = title->offset_y = 0.0f;
    title->isSelected = 0;
    title->scaleGrow = 0.0f;
    title->selectedOutline = 0.0f;
    title->outlineCounter = 0.0f;
}

void TitleBox_create2(TitleBox * title, sprite_t * image, char * id) {
    size_t id_length = strlen(id);
    if(id_length >= sizeof(title->id)) id_length = sizeof(title->id) - 1;
    memcpy(title->id, id, id_length);
    title->id[id_length] = 0;
    title->image = image;
    title->sprite.x = 0.0f;
    title->sprite.y = 0.0f;
    title->sprite.width = TITLE_BOX_WIDTH_E;
    title->sprite.height = TITLE_BOX_HEIGHT_E;
    title->scale = 1.0f;
    title->offset_x = title->offset_y = 0.0f;
    title->isSelected = 0;
    title->scaleGrow = 0.0f;
    title->selectedOutline = 0.0f;
    title->outlineCounter = 0.0f;
}

void TitleBox_update(TitleBox * title) {
    if(title->isSelected) {
        title->scaleGrow += 1.0f / 10.0f;
        if(title->scaleGrow > 1.0f) title->scaleGrow = 1.0f;
        //title->selectedOutline += 1.0f/10.0f;

        title->selectedOutline = 1.0f - (cos(title->outlineCounter) * 0.5f + 0.5f);
        //if(title->selectedOutline > 1.0f) title->selectedOutline = 1.0f;
        
        title->outlineCounter += 0.15f;
    } else {
        title->scaleGrow = 0.0f;
        title->selectedOutline = 0.0f;
        title->outlineCounter = 0.0f;
    }
}

void TitleBox_draw(TitleBox * title) {
    float titleScale = title->scale;
    float originalWidth = title->sprite.width * title->scale;
    float originalHeight = title->sprite.height * title->scale;
    if(title->isSelected) {
        float scaleHeight = (originalHeight + 8) / originalHeight;
        float scaleFactor = titleScale * scaleHeight;
        titleScale = titleScale + title->scaleGrow * (scaleFactor - titleScale);
    }

    // Center scale
    
    float scaledWidth = title->sprite.width * titleScale;
    float scaledHeight = title->sprite.height * titleScale;
    float scaledOffsetX = scaledWidth - originalWidth;
    float scaledOffsetY = scaledHeight - originalHeight;

    float offsetX = title->sprite.x - scaledOffsetX * 0.5f;
    float offsetY = title->sprite.y - scaledOffsetY * 0.5f;
    if(offsetX < box_region_min_x) offsetX = box_region_min_x;
    if((offsetX + scaledWidth) >= box_region_max_x) offsetX = box_region_max_x - scaledWidth;

    if(offsetY < box_region_min_y) offsetY = box_region_min_y;
    if((offsetY + scaledHeight) >= box_region_max_y) offsetY = box_region_max_y - scaledHeight;

    if((offsetY < viewport_y && (offsetY + scaledHeight) <= viewport_y) ||
    (offsetY >= viewport_y_bottom && (offsetY + scaledHeight) > viewport_y_bottom)) {
        return;
    }

    float screenY = offsetY - (viewport_y - BOX_REGION_Y_MIN);

    // Unselected art recedes into the black field; the active cover is the only one at full strength.
    float level = title->isSelected ? 1.0f : 0.40f;
    int b = title_brightness * level * 255.0f;
    rdpq_set_mode_standard();
    rdpq_mode_filter(FILTER_BILINEAR);
    rdpq_mode_combiner(RDPQ_COMBINER_TEX_FLAT);
    rdpq_set_prim_color(RGBA32(b, b, b, 255));
    rdpq_sprite_blit(title->image, offsetX, screenY, &(rdpq_blitparms_t){
        .scale_x = titleScale, .scale_y = titleScale,
    });

    if(title->isSelected) {
        focus_draw(offsetX - 3, screenY - 3, scaledWidth + 6, scaledHeight + 6);
    }
}


typedef struct MenuSidebar_s {
    SquareSprite sprite;
    float vertex[8];
    float width;
    int isOpen;
    int animCounter;
    int prevIsOpen;
} MenuSidebar;
MenuSidebar menu_sidebar;

void vertex_set_from_xywh(SquareSprite * sprite, float * out) {
    out[0] = sprite->x;
    out[1] = sprite->y;

    out[2] = sprite->x + sprite->width;
    out[3] = sprite->y + sprite->height;

    out[4] = out[0];
    out[5] = out[3];

    out[6] = out[2];
    out[7] = out[1];
}

int menu_sidebar_anim[] = {0, 10, 20, 30, 30, 20, 10, 0};

void menu_sidebar_update(MenuSidebar * obj) {
    vertex_set_from_xywh(&obj->sprite, obj->vertex);
    obj->prevIsOpen = obj->isOpen;
    if(cursor_x < 0) {
        obj->isOpen = 1;
    } else {
        obj->isOpen = 0;
    }

    if(obj->prevIsOpen != obj->isOpen) {
        if(obj->isOpen) {
        } else {
        }
    }

    if(obj->isOpen) {
        obj->animCounter++;
    } else {
        obj->animCounter--;
    }
    #define SIDE_MENU_OPN_FRM 10.0f

    if(obj->animCounter > SIDE_MENU_OPN_FRM) obj->animCounter = SIDE_MENU_OPN_FRM;
    if(obj->animCounter < 0) obj->animCounter = 0;

    float anmfact = obj->animCounter / SIDE_MENU_OPN_FRM;
    float interpl;
    
    if(obj->isOpen) {
        interpl = bezier_interp(anmfact, .44f,.88f,.57f,1.26f);
    } else {
        interpl = 1.0f - bezier_interp(1.0f - anmfact, .44f,.88f,.57f,1.15f);
    }
    obj->sprite.width = 64.0f + abs(interpl * 256.0f);
    title_brightness = 0.5f + (1.0f - anmfact) * 0.5f;





}
void menu_sidebar_draw(MenuSidebar * obj) {
    rdpq_set_prim_color(RGBA32(32, 13, 54, 255));
    rdpq_triangle(&TRIFMT_FILL, &obj->vertex[0], &obj->vertex[2], &obj->vertex[4]);
    rdpq_triangle(&TRIFMT_FILL, &obj->vertex[0], &obj->vertex[6], &obj->vertex[2]);
}


void setRomPath(char * code) {
    memset(rom_path, 0, sizeof(rom_path));
    strcpy(rom_path, "sd:/menu/title/");
    strcat(rom_path, code);
    strcat(rom_path, "/");
    strcat(rom_path, code);
    strcat(rom_path, "_e.z64");
}
flashcart_save_type_t getSaveType(char * code) {
    char path[128];
    char value[32] = {0};
    snprintf(path, sizeof(path), "sd:/menu/title/%s/%s_e.save", code, code);

    FILE * f = fopen(path, "r");
    if(f == NULL) return FLASHCART_SAVE_TYPE_NONE;
    fgets(value, sizeof(value), f);
    fclose(f);
    value[strcspn(value, "\r\n")] = 0;

    // Older library exports stored the enum as one digit. Keep accepting those
    // persisted sidecars while using names for all new files.
    if(strcmp(value, "none") == 0 || strcmp(value, "0") == 0) return FLASHCART_SAVE_TYPE_NONE;
    if(strcmp(value, "eeprom4k") == 0 || strcmp(value, "1") == 0) return FLASHCART_SAVE_TYPE_EEPROM_4K;
    if(strcmp(value, "eeprom16k") == 0 || strcmp(value, "2") == 0) return FLASHCART_SAVE_TYPE_EEPROM_16K;
    if(strcmp(value, "sram") == 0 || strcmp(value, "3") == 0) return FLASHCART_SAVE_TYPE_SRAM;
    if(strcmp(value, "srambanked") == 0 || strcmp(value, "4") == 0) return FLASHCART_SAVE_TYPE_SRAM_BANKED;
    if(strcmp(value, "sram128k") == 0 || strcmp(value, "5") == 0) return FLASHCART_SAVE_TYPE_SRAM_128K;
    if(strcmp(value, "flashram") == 0 || strcmp(value, "6") == 0) return FLASHCART_SAVE_TYPE_FLASHRAM;
    if(strcmp(value, "flashram-pkst2") == 0 || strcmp(value, "7") == 0) return FLASHCART_SAVE_TYPE_FLASHRAM_PKST2;
    return FLASHCART_SAVE_TYPE_NONE;
}
bool setupRomLoad(TitleBox * title) {
    setRomPath(title->id);

    if(flashcart_load_rom(rom_path, false, cart_load_progress) != FLASHCART_OK) return false;

    flashcart_save_type_t save_type = getSaveType(title->id);
    if(save_type == FLASHCART_SAVE_TYPE_NONE) {
        if(flashcart_load_save(NULL, save_type) != FLASHCART_OK) return false;
    } else {
        char save_path[128];
        directory_create("sd:/menu/save");
        snprintf(save_path, sizeof(save_path), "sd:/menu/save/%s.sav", title->id);
        if(flashcart_load_save(save_path, save_type) != FLASHCART_OK) return false;
    }

    //boot_params.reset_type = BOOT_RESET_TYPE_NMI;
    boot_params.device_type = BOOT_DEVICE_TYPE_ROM;
    boot_params.tv_type = BOOT_TV_TYPE_PASSTHROUGH;
    boot_params.detect_cic_seed = true;

    menu_active = false;
    return true;
}

void load_titles() {
    int row_max = TITLE_COLUMNS;

    //row_max = 4; // Quick hack to reduce the number of titles per row

    FILE * f = fopen("sd://menu/title.csv", "r");
    if(f != NULL){
        setvbuf(f, NULL, _IONBF, 0);
        fseek(f, 0, SEEK_END);
        long csvsize = ftell(f);
        fseek(f, 0, SEEK_SET);

        if(csvsize < 0) csvsize = 0;
        if(csvsize > TITLE_CSV_MAX) {
            // Read only what we will parse rather than overrunning the buffer.
            csvsize = TITLE_CSV_MAX;
            title_truncated = 1;
        }

        size_t read = fread(title_csv, 1, csvsize, f);
        title_csv[read] = 0;
        fclose(f);

        char flbuf[TITLE_ID_MAX + 1];
        int flbfpos = 0;
        bool invalid_id = false;
        title_count = 0;

        for(char * it = title_csv; ; it++) {
            char c = *it;
            if(c == ',' || c == ' ' || c == '\r' || c == '\n' || c == 0) {
                if(flbfpos != 0 && !invalid_id) {
                    flbuf[flbfpos] = 0;

                    if(title_count >= MAX_TITLE_COUNT || (title_count / row_max) >= TITLE_ROWS) {
                        title_truncated = 1;
                        break;
                    }

                    char filename[64];
                    snprintf(filename, sizeof(filename), "sd:/menu/title/%s/%s_e.sprite", flbuf, flbuf);

                    sprite_t * image = sprite_load(filename);
                    TitleBox_create2(&title_list[title_count], image, flbuf);
                    if((title_count % row_max) == 0) {
                        library_row_initial[title_count / row_max] = title_initial_load(flbuf);
                    }
                    title_row[title_count / row_max][title_count % row_max] = &title_list[title_count];
                    title_count++;
                }
                flbfpos = 0;
                invalid_id = false;
            } else if(flbfpos < TITLE_ID_MAX) {
                flbuf[flbfpos] = c;
                flbfpos++;
            } else {
                // Consume an oversized token, but never add its truncated prefix.
                invalid_id = true;
                title_truncated = 1;
            }

            if(c == 0) break;
        }
    }

    library_populated_rows = (title_count + row_max - 1) / row_max;

    for(int y = 0; y < TITLE_ROWS; y++) { 
        int row_count = 0;
        for(int x = 0; x < row_max; x++) {
            if(title_row[y][x] != NULL) row_count++;
        }
        title_row_count[y] = row_count;
    }
    
    // Fixed tile pitch with real gutters, rather than scaling covers to fill the row edge-to-edge.
    float tileWidth = (BOX_REGION_X_MAX - BOX_REGION_X_MIN - GRID_GUTTER * (TITLE_COLUMNS - 1)) / TITLE_COLUMNS;
    float rowScale = tileWidth / TITLE_BOX_WIDTH_E;
    float tileHeight = TITLE_BOX_HEIGHT_E * rowScale;

    float currentRowY = box_region_min_y;
    for(int y = 0; y < TITLE_ROWS; y++) {
        int currentRowCount = title_row_count[y];
        if(currentRowCount == 0) continue;

        for(int x = 0; x < row_max; x++) {
            TitleBox * current = title_row[y][x];
            if(current == NULL) continue;
            current->scale = rowScale;

            current->sprite.x = BOX_REGION_X_MIN + (tileWidth + GRID_GUTTER) * x;
            current->sprite.y = currentRowY;

        }
        currentRowY += tileHeight + GRID_GUTTER;
    }

    if(currentRowY > SCREEN_HEIGHT) {
        box_region_max_y = currentRowY;
    }
}

float gametitle_fade = 0.0f;
SquareSprite gametitle_fade_sprite;
float gametitle_fade_vertex[8];

void menu_update() {

    menu_sidebar_update(&menu_sidebar);

    int prev_cursor_x = cursor_x;
    int prev_cursor_y = cursor_y;

    int limit_reached = 0;
    int cursor_move = 0;

    int currentRowCount = title_row_count[cursor_y];

    if(main_state == 3) {
        int input_x = 0;
        int input_y = 0;
        
        if(p1_buttons.d_left) {
            input_x = -1;
        }
        if(p1_buttons.d_right) {
            input_x = 1;
        }
        if(p1_inputs.stick_x < -30 || p1_inputs.stick_x > 30) {
            input_x = p1_inputs.stick_x;
        }

        if(p1_buttons.d_up) {
            input_y = -1;
        }
        if(p1_buttons.d_down) {
            input_y = 1;
        }
        if(p1_inputs.stick_y < -30 || p1_inputs.stick_y > 30) {
            input_y = -p1_inputs.stick_y;
        }
        
        if(input_x < 0) {
            if(cursor_x_timer == 0){ 
                cursor_x--;
            }
            cursor_x_timer++;
            if(cursor_x_timer > CURSOR_INTERVAL) {
                cursor_x--;
                cursor_x_timer = CURSOR_INTERVAL_SECOND;
            }
        } else if(input_x > 0) {
            if(cursor_x_timer == 0){ 
                cursor_x++;
            }
            cursor_x_timer++;
            if(cursor_x_timer > CURSOR_INTERVAL) {
                cursor_x++;
                cursor_x_timer = CURSOR_INTERVAL_SECOND;
            }
        } else {
            cursor_x_timer = 0;
        }
        // No lateral menu in this theme: pressing left at the first column must not
        // drop into a selection-less state.
        if(cursor_x < 0) cursor_x = 0;
        if(cursor_x >= 0) {
            if(input_y < 0) {
                if(cursor_y_timer == 0){ 
                    cursor_y--;
                }
                cursor_y_timer++;
                if(cursor_y_timer > CURSOR_INTERVAL) {
                    cursor_y--;
                    cursor_y_timer = CURSOR_INTERVAL_SECOND;
                }
            } else if(input_y > 0) {
                if(cursor_y_timer == 0){ 
                    cursor_y++;
                }
                cursor_y_timer++;
                if(cursor_y_timer > CURSOR_INTERVAL) {
                    cursor_y++;
                    cursor_y_timer = CURSOR_INTERVAL_SECOND;
                }
            } else {
                cursor_y_timer = 0;
            }
        }
    }

    if(cursor_x >= 0) {
        if(cursor_y < 0) {
            if(prev_cursor_y != cursor_y) limit_reached = 1;
            cursor_y = 0;
        } else if (cursor_y >= TITLE_ROWS) {
            if(prev_cursor_y != cursor_y) limit_reached = 1;
            cursor_y = TITLE_ROWS-1;
        }

        // Next row?
        int rowCount = title_row_count[cursor_y];
        if(rowCount == 0) {
            cursor_y--;
            limit_reached = 1;
            rowCount = title_row_count[cursor_y];
        } else {
            if(prev_cursor_y != cursor_y) cursor_move = 1;
        }

    
        // Select most fitting x based on title sizes
        if(rowCount > 1) {
            float nextFitting = ((float)cursor_x + 0.5f) / (float)currentRowCount;
            cursor_x = nextFitting * rowCount;
        }
        
        if(cursor_x < 0) {
            if(prev_cursor_x != cursor_x) {
                limit_reached = 1;
            }
            cursor_x = 0;

        } else if(cursor_x >= rowCount) {
            if(prev_cursor_x != cursor_x) {
                limit_reached = 1;
            }
            cursor_x = rowCount - 1;
        } else {
            if(prev_cursor_x != cursor_x) {
                cursor_move = 1;
            }
            
        }
    } else {
        // Lateral menu activated
        if(cursor_x < -1) {
            cursor_x = -1;
        }
    }
    

    if(limit_reached) {
    }
    if(cursor_move) {
    }

    if(cursor_x >= 0) {
        TitleBox * cur = title_row[cursor_y][cursor_x];
        if(cur != NULL) {
            if(selectedTitle != NULL) {
                selectedTitle->isSelected = 0;
            }
            cur->isSelected = 1;
            selectedTitle = cur;
        }
    } else {
        if(selectedTitle != NULL) {
            selectedTitle->isSelected = 0;
        }
        selectedTitle = NULL;
    }

    int populated_rows = (title_count + TITLE_COLUMNS - 1) / TITLE_COLUMNS;
    int visible_rows = populated_rows < 5 ? populated_rows : 5;
    if(cursor_y < library_row_window_start) {
        library_row_window_start = cursor_y;
    } else if(cursor_y >= library_row_window_start + visible_rows) {
        library_row_window_start = cursor_y - visible_rows + 1;
    }
    int max_window_start = populated_rows - visible_rows;
    if(library_row_window_start > max_window_start) library_row_window_start = max_window_start;
    if(library_row_window_start < 0) library_row_window_start = 0;
    library_position_segment = cursor_y - library_row_window_start;

    if(cursor_x >= 0 && selectedTitle && main_state == 3) {
        if(p1_buttons_press.a) {
            main_state = 4;
            selectedTitle->scaleGrow = 0.0f;
        }
    }

    

    for(int y = 0; y < TITLE_ROWS; y++) {
        for(int x = 0; x < TITLE_COLUMNS; x++) {
            TitleBox * current = title_row[y][x];
            if(current == NULL) continue;
            TitleBox_update(current);
        }
    }

    if(selectedTitle) {
        float viewMidpoint = 240.0f;
        float midpointY = selectedTitle->sprite.y + (selectedTitle->sprite.height * 0.5);
        viewport_y_target = midpointY - viewMidpoint;

        if(viewport_y_target < box_region_min_y) viewport_y_target = box_region_min_y;
        if((viewport_y_target + (BOX_REGION_Y_MAX - BOX_REGION_Y_MIN)) > box_region_max_y) viewport_y_target = box_region_max_y - (BOX_REGION_Y_MAX - BOX_REGION_Y_MIN);
        viewport_y_target = round(viewport_y_target);
    }
    
    float vydiff = viewport_y_target - viewport_y;
    if(abs(vydiff) > 0.1f) {
        viewport_y += (viewport_y_target - viewport_y) * 0.4f;
    } else {
        viewport_y = viewport_y_target;
    }

    viewport_y_bottom = viewport_y + (BOX_REGION_Y_MAX - BOX_REGION_Y_MIN);

    // fade out
    if(main_state > 3) {
        switch(main_state) {
            case 4:
                gametitle_fade += 1.0f / 15.0f;
                if(gametitle_fade >= 1.0f) {
                    gametitle_fade = 1.0f;
                    main_state = 5;
                }
                break;
            case 5:
                if(!setupRomLoad(selectedTitle) || p1_buttons_press.b) {
                    main_state = 6;
                    spinner_fade = 0.0f;
                    spinner_fade_counter = 0;
                    spinner_counter = 0.0f;
                }
                break;
            case 6:
                gametitle_fade -= 1.0f / 20.0f;
                if(gametitle_fade <= 0.0f) {
                    gametitle_fade = 0.0f;
                    main_state = 3;
                }
                break;
        }
        float midpointX = selectedTitle->sprite.x + (selectedTitle->sprite.width * selectedTitle->scale) * 0.5;
        float midpointY = selectedTitle->sprite.y + (selectedTitle->sprite.height * selectedTitle->scale) * 0.5;
        midpointY -= (viewport_y - BOX_REGION_Y_MIN);
        gametitle_fade_sprite.x = lerp(gametitle_fade, midpointX - 32.0f, 0.0f);
        gametitle_fade_sprite.y = lerp(gametitle_fade, midpointY - 32.0f, 0.0f);
        gametitle_fade_sprite.width = lerp(gametitle_fade, 64.0f, 640.0f);
        gametitle_fade_sprite.height = lerp(gametitle_fade, 64.0f, 480.0f);
        vertex_set_from_xywh(&gametitle_fade_sprite, gametitle_fade_vertex);
    }


}
void menu_draw() {
    rdpq_set_mode_standard();
    rdpq_mode_combiner(RDPQ_COMBINER_FLAT);    
    
    if(main_state != 5) {
        // Scissor left of the grid so the selection marker has room; the old NSO
        // left rail no longer exists in this theme.
        rdpq_set_scissor(GRID_SCISSOR_X_MIN, GRID_SCISSOR_Y_MIN,
            GRID_SCISSOR_X_MAX, GRID_SCISSOR_Y_MAX);

        rdpq_mode_combiner(RDPQ_COMBINER_TEX_FLAT);
        
        rdpq_mode_filter(FILTER_BILINEAR);

        for(int y = 0; y < TITLE_ROWS; y++) {
            for(int x = 0; x < TITLE_COLUMNS; x++) {
                TitleBox * current = title_row[y][x];
                if(current == NULL || current == selectedTitle) continue;
                TitleBox_draw(current);
            }
        }
        if(selectedTitle != NULL) {
            // Draw last
            TitleBox_draw(selectedTitle);
        }

    }

    if(main_state > 3) {
        float gametitle_fade_c = gametitle_fade * 255.0f;
        rdpq_set_mode_standard();
        rdpq_mode_combiner(RDPQ_COMBINER_FLAT);
        rdpq_mode_blender(RDPQ_BLENDER_MULTIPLY);
        rdpq_set_prim_color(RGBA32(0, 0, 0, gametitle_fade_c));
        rdpq_triangle(&TRIFMT_FILL, &gametitle_fade_vertex[0], &gametitle_fade_vertex[2], &gametitle_fade_vertex[4]);
        rdpq_triangle(&TRIFMT_FILL, &gametitle_fade_vertex[0], &gametitle_fade_vertex[6], &gametitle_fade_vertex[2]);
        if(main_state == 5) {
            spinner_fade_counter++;
            if(spinner_fade_counter >= 10) {
                spinner_fade = (spinner_fade_counter - 10) / 30.0f;
                if(spinner_fade > 1.0f) spinner_fade = 1.0f;

                spinner_draw(640 - 55, 480 - 48, 20, spinner_fade);
            }
        }
    }
}

void update(int ovfl) {
    switch(fade_state) {
        case 0:
        fade_lvl = fade_counter / FADE_DURATION;
        fade_counter--;
        if(fade_counter == 0) fade_state = 1;
        break;
        default:
        break;
    }

    if(fade_state == 1 && main_state == 0) {
        main_state = 1;
    }
    switch(main_state) {
        default: case 0: break; // Wait Fade
        case 1: // Wait logo
            opening_counter--;
            if(opening_counter == OPENING_SOUND_PLAY) {
                
            }
            if(opening_counter == 0) {
                main_state = 2;
                load_titles();
                opening_counter = OPENING_OUT;
            }
        break;
        case 2: // exit logo out of the screen
            opening_card_offset_x = ((1.0f - opening_counter / OPENING_OUT) * 640.0f);
            opening_counter--;
            if(opening_counter == 0) {
                main_state = 3;
            }
            break;
    }

    if(main_state >= 2) menu_update();

    // Only while browsing: launching a game already owns the boot path.
    if(main_state == 3) usb_upload_poll();
}

void draw(int cur_frame) {
    surface_t *disp = display_get();
    rdpq_attach(disp, NULL);

    if(main_state >= 2) {
        rdpq_set_scissor(0, 0, SCREEN_WIDTH, SCREEN_HEIGHT);
        chrome_draw();
        rdpq_set_scissor(GRID_SCISSOR_X_MIN, GRID_SCISSOR_Y_MIN,
            GRID_SCISSOR_X_MAX, GRID_SCISSOR_Y_MAX);
        menu_draw();

        rdpq_set_scissor(0, 0, SCREEN_WIDTH, SCREEN_HEIGHT);
        // A section label rather than a page title, so it sits at body size. The
        // ribbon and the mark already carry the top of the screen.
        rdpq_text_print(NULL, FONT_BODY, BOX_REGION_X_MIN, 104, "LIBRARY");

        // The count carries the emphasis and the word stays secondary, which lifts
        // the figure without turning the whole line into another heading. The old
        // dim violet was chosen against black and lost most of its contrast once the
        // ground became violet too.
        rdpq_text_printf(NULL, FONT_SMALL, BOX_REGION_X_MIN, HINT_Y + 12,
            title_truncated ? "^00%d ^02TITLES (LIMIT)" : "^00%d ^02TITLES", title_count);

        // Circular M64-style caps. The letter is centred on the cap and drawn in
        // black, so it reads as printed on the button rather than floating over it.
        button_cap_draw(427, HINT_Y + 9,
            RGBA32(0, 50, 150, 255), RGBA32(0, 104, 230, 255), RGBA32(62, 160, 255, 255));
        button_letter_draw(427, HINT_Y + 9, "^05A");
        rdpq_text_print(NULL, FONT_SMALL, 446, HINT_Y + 14, "PLAY");

        button_cap_draw(527, HINT_Y + 9,
            RGBA32(0, 96, 40, 255), RGBA32(0, 183, 73, 255), RGBA32(55, 235, 120, 255));
        button_letter_draw(527, HINT_Y + 9, "^05B");
        rdpq_text_print(NULL, FONT_SMALL, 546, HINT_Y + 14, "BACK");
    }


    if(main_state < 3) {
        rdpq_set_scissor(0, 0, SCREEN_WIDTH, SCREEN_HEIGHT);
        background_draw();

        // Centred mark over a pink rule, matching the header treatment.
        float lw = logo_splash->width * LOGO_SCALE;
        float lh = logo_splash->height * LOGO_SCALE;
        float lx = (SCREEN_WIDTH - lw) * 0.5f - opening_card_offset_x;
        float ly = 176.0f;
        logo_draw(logo_splash, logo_splash_inner, lx, ly);

        rdpq_set_mode_fill(RGBA32(255, 35, 156, 255));
        float rx0 = lx < 0.0f ? 0.0f : lx;
        float rx1 = lx + lw > SCREEN_WIDTH ? SCREEN_WIDTH : lx + lw;
        if(rx1 > rx0) {
            rdpq_fill_rectangle(rx0, ly + lh + 14, rx1, ly + lh + 17);
        }
    }


     // Draw Fade
    if(fade_state != 1) {
        rdpq_set_mode_standard();
        rdpq_mode_dithering(DITHER_NOISE_NOISE);
        rdpq_mode_combiner(RDPQ_COMBINER_FLAT);
        rdpq_mode_blender(RDPQ_BLENDER_MULTIPLY);
        rdpq_set_prim_color(RGBA32(0, 0, 0, fade_lvl * 255));
        rdpq_triangle(&TRIFMT_FILL, fade_v1, fade_v2, fade_v3);
        rdpq_triangle(&TRIFMT_FILL, fade_v1, fade_v4, fade_v2);
    }

    // For measuring performance
    /*float fps = display_get_fps();
    rdpq_text_printf(&(rdpq_textparms_t){
        .align = ALIGN_LEFT,
        .width = 400,
    }, 1, 32, 55, "FPS: %.4f", fps);*/

    rdpq_detach_show();
}

int main(void)
{
    /* Initialize peripherals */
    // No VI filtering: the menu is flat colour and pixel art, so dedither only
    // softens it, and the console's own UI is crisp by comparison.
    display_init(RESOLUTION_640x480, DEPTH_16_BPP, 3, GAMMA_NONE, FILTERS_DISABLED);
    dfs_init( DFS_DEFAULT_LOCATION );
    debug_init_sdfs("sd:/", -1);
    rdpq_init();
    joypad_init();
    timer_init();

    logo_header = sprite_load("rom:/sc64_logo_header.sprite");
    logo_splash = sprite_load("rom:/sc64_logo_splash.sprite");
    logo_header_inner = sprite_load("rom:/sc64_logo_header_inner.sprite");
    logo_splash_inner = sprite_load("rom:/sc64_logo_splash_inner.sprite");

    font_body = rdpq_font_load("rom:/m64_body.font64");
    font_title = rdpq_font_load("rom:/m64_title.font64");
    font_small = rdpq_font_load("rom:/m64_small.font64");
    font_cap = rdpq_font_load("rom:/m64_cap.font64");
    rdpq_text_register_font(FONT_BODY, font_body);
    rdpq_text_register_font(FONT_TITLE, font_title);
    rdpq_text_register_font(FONT_SMALL, font_small);
    rdpq_text_register_font(FONT_CAP, font_cap);

    rdpq_fontstyle_t white  = { .color = RGBA32(255, 255, 255, 255) };
    rdpq_fontstyle_t yellow = { .color = RGBA32(255, 214, 0, 255) };
    // Secondary text. The old value was picked against black and sank once the ground
    // became violet. It still has to sit clearly below white, or pairing the two
    // conveys no hierarchy: grey against white measured 725 against 765, which is not
    // a difference anyone can see.
    rdpq_fontstyle_t dim    = { .color = RGBA32(178, 168, 198, 255) };
    rdpq_fontstyle_t grey   = { .color = RGBA32(206, 206, 216, 255) };
    // Shadows are a darkened tint of the tab they fall on, not black, so they
    // read as cast onto the surface instead of punched through it.
    rdpq_fontstyle_t shadow = { .color = RGBA32(44, 18, 78, 255) };
    rdpq_fontstyle_t shadowsel = { .color = RGBA32(170, 16, 82, 255) };
    rdpq_fontstyle_t keyline= { .color = RGBA32(0, 0, 0, 255) };
    rdpq_font_style(font_body,  STYLE_WHITE,  &white);
    rdpq_font_style(font_body,  STYLE_YELLOW, &yellow);
    rdpq_font_style(font_body,  STYLE_DIM,    &dim);
    rdpq_font_style(font_body,  STYLE_GREY,   &grey);
    rdpq_font_style(font_body,  STYLE_SHADOW, &shadow);
    rdpq_font_style(font_body,  STYLE_OUTLINE,&keyline);
    rdpq_font_style(font_body,  STYLE_SHADOW_SEL, &shadowsel);
    rdpq_font_style(font_title, STYLE_WHITE,  &white);
    rdpq_font_style(font_title, STYLE_YELLOW, &yellow);
    rdpq_font_style(font_small, STYLE_WHITE, &white);
    rdpq_font_style(font_small, STYLE_DIM, &dim);
    rdpq_font_style(font_small, STYLE_GREY, &grey);
    rdpq_font_style(font_small, STYLE_OUTLINE, &keyline);
    rdpq_font_style(font_cap, STYLE_OUTLINE, &keyline);


    menu_sidebar.sprite.x = 0;
    menu_sidebar.sprite.y = 0;
    menu_sidebar.sprite.width = 64;
    menu_sidebar.sprite.height = 480;
    menu_sidebar.width = 64.0f;
    menu_sidebar.isOpen = 0;
    menu_sidebar.animCounter = 0;

    flashcart_init();
    
    int cur_frame = 0;
    menu_active = 1;
    while(menu_active) {
        update(0);
        draw(cur_frame);
        joypad_poll();
        p1_buttons = joypad_get_buttons(JOYPAD_PORT_1);
        p1_buttons_press = joypad_get_buttons_pressed(JOYPAD_PORT_1);
        p1_inputs = joypad_get_inputs(JOYPAD_PORT_1);
        cur_frame++;
    }

    flashcart_deinit();


    rdpq_close();
    rspq_close();
    timer_close();
    joypad_close();

    display_close();

    disable_interrupts();

    boot(&boot_params);

    assertf(false, "Unexpected return from 'boot' function");

    while (true) {

    }
}
