#include <stdio.h>

#include <libdragon.h>

#include "boot/boot.h"
#include "flashcart/flashcart.h"

#define PI 3.141592653f
#define PI2 (PI*2.0f)

#define RDPQ_COMBINER_TEX_ALPHA   RDPQ_COMBINER1((0,0,0,PRIM),    (TEX0,0,PRIM,0))

int menu_active;
boot_params_t boot_params;
char rom_path[1024];

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

sprite_t *logo;
sprite_t *shadow;
sprite_t *loading_dot;

int spinner_fade_counter = 0;
float spinner_fade = 0.0f;
float spinner_counter = 0.0f;

void spinner_draw(float x, float y, float size, float alpha) {
    float dot_size = (11.0f * 0.5f) * 0.4f;
    rdpq_set_prim_color(RGBA32(255, 255, 255, alpha * 255.0f));
    rdpq_mode_combiner(RDPQ_COMBINER_TEX_ALPHA);
    rdpq_mode_blender(RDPQ_BLENDER_MULTIPLY);
    for(int a = 11; a >= 0 ; a--) {
        float thisAnimSize = (12.0f - fmod((spinner_counter + a),12.0f))- 9.0f;
        if(thisAnimSize < 0.0f) thisAnimSize = 0.0f;
        float animParam = thisAnimSize / 3.0f;
        float scaled = 0.4f + (animParam * 0.6f);
        float dot_ang = (a / 12.0f) * PI2;
        float dot_x = (x + sin(dot_ang) * size) - dot_size * scaled;
        float dot_y = (y + cos(dot_ang) * size) - dot_size * scaled;
        rdpq_sprite_blit(loading_dot, dot_x, dot_y, &(rdpq_blitparms_t){
            .scale_x = scaled, .scale_y = scaled,
        });
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

rdpq_font_t * font;

static wav64_t se_titlelogo;
static wav64_t se_cursor_ng;
static wav64_t se_gametitle_cursor;
static wav64_t se_filemenu_close;
static wav64_t se_filemenu_open;
static wav64_t se_gametitle_click; 

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
#define BOX_REGION_X_MAX 624.0f
#define BOX_REGION_Y_MIN 16.0f
#define BOX_REGION_Y_MAX 464.0f

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

float shadow_vertex[8];

void shadow_draw(float x, float y, float width, float height, float alpha) {
    // Load shadow sprite surface
    surface_t surf = sprite_get_pixels(shadow);
    rdpq_set_prim_color(RGBA32(0, 0, 0, alpha * 255.0f));
    rdpq_mode_combiner(RDPQ_COMBINER_TEX_ALPHA);
    rdpq_mode_blender(RDPQ_BLENDER_MULTIPLY);
    rdpq_mode_dithering(DITHER_BAYER_BAYER);
    rdpq_mode_tlut(TLUT_NONE);
    rdpq_tex_upload(TILE0, &surf, &(rdpq_texparms_t){.s.repeats = 1, .t.repeats = 1});

    float xw = x + width;
    float yh = y + height;

    rdpq_triangle(&TRIFMT_TEX,
        (float[]){ x,  y,  0.0f, 0.0f, 1.0f },
        (float[]){xw,  y, 64.0f, 0.0f, 1.0f },
        (float[]){xw, yh, 64.0f,64.0f, 1.0f }
    );

    rdpq_triangle(&TRIFMT_TEX,
        (float[]){ x,  y,  0.0f, 0.0f, 1.0f },
        (float[]){xw, yh, 64.0f,64.0f, 1.0f },
        (float[]){ x, yh, 64.0f, 0.0f, 1.0f }
    );
    
    // Revert combiner
    rdpq_mode_combiner(RDPQ_COMBINER_TEX_FLAT);
}

void outline_draw(float x, float y, float width, float height, float brightness) {
    #define OUTLINE_WIDTH 1
    int brightv = brightness * 255.0f;
    x = round(x);
    y = round(y);
    width = ceil(width);
    height = ceil(height);
    rdpq_set_mode_fill(RGBA32(brightv,brightv,brightv,0));
    rdpq_fill_rectangle(x, y, x + width, y + OUTLINE_WIDTH);
    rdpq_fill_rectangle(x, y+height-OUTLINE_WIDTH, x + width, y + height);
    rdpq_fill_rectangle(x, y, x+OUTLINE_WIDTH, y+height);
    rdpq_fill_rectangle(x+width-OUTLINE_WIDTH, y, x+width, y+height);
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
    memcpy(title->id, id, 8);
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
        float scaleHeight = (originalHeight + 16) / originalHeight;
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

    if(title->isSelected) {
        float shadow_scaleX = titleScale * 1.1f;  
        float shadow_scaleY = titleScale * 1.05f; 
        float shadowSizeX = scaledWidth * shadow_scaleX;
        float shadowSizeY = scaledHeight * shadow_scaleY;
        float shadowOffsetX = offsetX - (shadowSizeX - scaledWidth) * 0.5f;
        
        shadow_draw(shadowOffsetX, offsetY - (viewport_y - BOX_REGION_Y_MIN), shadowSizeX, shadowSizeY, 0.23f);
    }
    int b = title_brightness * 255.0f;
    rdpq_set_prim_color(RGBA32(b, b, b, 255));
    rdpq_sprite_blit(title->image, offsetX, offsetY - (viewport_y - BOX_REGION_Y_MIN), &(rdpq_blitparms_t){
        .scale_x = titleScale, .scale_y = titleScale,
    });

    if(title->isSelected) {
        outline_draw(
            offsetX, offsetY - (viewport_y - BOX_REGION_Y_MIN),
            title->sprite.width * titleScale, title->sprite.height * titleScale,
            title->selectedOutline
        );
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
            wav64_play(&se_filemenu_open, CHANNEL_SFX1);            
        } else {
            wav64_play(&se_filemenu_close, CHANNEL_SFX1);
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
    rdpq_set_prim_color(RGBA32(255, 0, 0, 0));
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
void setupRomLoad(TitleBox * title) {
    setRomPath(title->id);

    flashcart_load_rom(rom_path, false, cart_load_progress);

    //boot_params.reset_type = BOOT_RESET_TYPE_NMI;
    boot_params.device_type = BOOT_DEVICE_TYPE_ROM;
    boot_params.tv_type = BOOT_TV_TYPE_PASSTHROUGH;
    boot_params.detect_cic_seed = true;

     menu_active = false;
}

void load_titles() {
    int row_max = TITLE_COLUMNS;

    //row_max = 4; // Quick hack to reduce the number of titles per row

    char pathstr[256];
    strcpy(pathstr, "sd:/menu/title/");
    
    FILE * f = fopen("sd://menu/title.csv", "r");
    if(f != NULL){
        setvbuf(f, NULL, _IONBF, 0);
        fseek(f, 0, SEEK_END);
        int csvsize = ftell(f);
        fseek(f, 0, SEEK_SET);
        fread(pathstr, 1, csvsize, f);
        fclose(f);
        char * pathstritr = pathstr;
        char flbuf[8];
        int flbfpos = 0;
        title_count = 0;
        do {
            if(*pathstritr == ',' || *pathstritr == ' ' || *pathstritr == 0x0) {
                if(flbfpos != 0) {
                    char filename[64];
                    flbuf[flbfpos] = 0;
                    strcpy(filename, "sd:/menu/title/");
                    strcat(filename, flbuf);
                    strcat(filename, "/");
                    strcat(filename, flbuf);
                    strcat(filename, "_e.sprite");
                    TitleBox_create2(&title_list[title_count], sprite_load(filename), flbuf);
                    title_row[title_count/row_max][title_count%row_max] = &title_list[title_count];
                    title_count++;
                }
                flbfpos = 0;
            } else {
                flbuf[flbfpos] = *pathstritr;
                flbfpos++;
            }
            pathstritr++;
        } while(*pathstritr != 0x00);
    }

    for(int y = 0; y < TITLE_ROWS; y++) { 
        int row_count = 0;
        for(int x = 0; x < row_max; x++) {
            if(title_row[y][x] != NULL) row_count++;
        }
        title_row_count[y] = row_count;
    }
    
    float currentRowY = box_region_min_y;
    for(int y = 0; y < TITLE_ROWS; y++) {
        int currentRowCount = title_row_count[y];
        if(currentRowCount == 0) continue;
        float rowScale = 1.0f;
        if(currentRowCount > 2) {
            rowScale = (BOX_REGION_X_MAX - BOX_REGION_X_MIN)  / (currentRowCount * TITLE_BOX_WIDTH_E);
        }
        float scaledTitleX = TITLE_BOX_WIDTH_E * rowScale;
        
        for(int x = 0; x < row_max; x++) {
            TitleBox * current = title_row[y][x];
            if(current == NULL) continue;
            current->scale = rowScale;

            current->sprite.x = box_region_min_x + scaledTitleX * x;
            current->sprite.y = currentRowY;

        }
        currentRowY += TITLE_BOX_HEIGHT_E * rowScale;
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
        wav64_play(&se_cursor_ng, CHANNEL_SFX1);
    }
    if(cursor_move) {
        wav64_play(&se_gametitle_cursor, CHANNEL_SFX1);
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

    if(cursor_x >= 0 && selectedTitle && main_state == 3) {
        if(p1_buttons_press.a) {
            main_state = 4;
            selectedTitle->scaleGrow = 0.0f;
            wav64_play(&se_gametitle_click, CHANNEL_SFX1);
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
                setupRomLoad(selectedTitle);
                if(p1_buttons_press.b) {
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
        int minSciss = opening_card_offset_x < menu_sidebar.sprite.width ? opening_card_offset_x : menu_sidebar.sprite.width;
        rdpq_set_scissor(minSciss,BOX_REGION_Y_MIN,BOX_REGION_X_MAX,BOX_REGION_Y_MAX);

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

        rdpq_set_scissor(BOX_REGION_Y_MIN,BOX_REGION_Y_MIN,BOX_REGION_X_MAX,BOX_REGION_Y_MAX);

        rdpq_set_mode_standard();
        rdpq_mode_combiner(RDPQ_COMBINER_FLAT);
        
        menu_sidebar_draw(&menu_sidebar);

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
                
                wav64_play(&se_titlelogo, CHANNEL_SFX1);
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
                sprite_free(logo);
            }
            break;
    }

    if(main_state >= 2) menu_update();
}

void draw(int cur_frame) {
    surface_t *disp = display_get();
    rdpq_attach(disp, NULL);

    rdpq_set_scissor(SCR_REGION_X_MIN,BOX_REGION_Y_MIN,BOX_REGION_X_MAX,BOX_REGION_Y_MAX);

    if(main_state >= 2) {
        rdpq_set_mode_fill(RGBA32(48,48,48,0));
        rdpq_fill_rectangle(64, BOX_REGION_Y_MIN, BOX_REGION_X_MAX, BOX_REGION_Y_MAX);
        menu_draw();
    }

    if(main_state < 3) { 
        rdpq_set_mode_fill(RGBA32(255,0,0,0));
        rdpq_fill_rectangle(SCR_REGION_X_MIN, BOX_REGION_Y_MIN, 640 - opening_card_offset_x, BOX_REGION_Y_MAX);

        rdpq_set_mode_copy(true);

        rdpq_sprite_blit(logo, 194 - opening_card_offset_x, 112, &(rdpq_blitparms_t){
            .scale_x = 1, .scale_y = 1,
        });
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
    display_init(RESOLUTION_640x480, DEPTH_16_BPP, 3, GAMMA_NONE, FILTERS_DEDITHER);
    dfs_init( DFS_DEFAULT_LOCATION );
    debug_init_sdfs("sd:/", -1);
    rdpq_init();
    joypad_init();
    timer_init();

    audio_init(44100, 4);
	mixer_init(20);

    wav64_open(&se_titlelogo, "rom:/se/titlelogo.wav64");
    wav64_open(&se_cursor_ng, "rom:/se/cursor_ng.wav64");
    wav64_open(&se_gametitle_cursor, "rom:/se/gametitle_cursor.wav64");
    wav64_open(&se_filemenu_close, "rom:/se/filemenu_close.wav64");
    wav64_open(&se_filemenu_open, "rom:/se/filemenu_open.wav64");
    wav64_open(&se_gametitle_click, "rom:/se/gametitle_click.wav64");
    
    logo = sprite_load("rom:/logo.sprite");
    shadow = sprite_load("rom:/shadow.sprite");
    loading_dot = sprite_load("rom:/loading_dot.sprite");
    font = rdpq_font_load("rom:/default.font64");
    rdpq_text_register_font(1, font);
    

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
        mixer_try_play();
        cur_frame++;
    }

    flashcart_deinit();


	mixer_close();
    audio_close();

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