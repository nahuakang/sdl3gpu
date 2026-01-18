Font :: void;

GPU_Atlas_Draw_Sequence :: struct {
    atlas_texture: *GPU_Texture;             /**< Texture atlas that stores the glyphs */
    xy:            *F_Point;                 /**< An array of vertex positions */
    uv:            *F_Point;                 /**< An array of normalized texture coordinates for each vertex */
    num_vertices:  s32;                      /**< Number of vertices */
    indices:       *s32;                     /**< An array of indices into the 'vertices' arrays */
    num_indices:   s32;                      /**< Number of indices */
    image_type:    Image_Type;               /**< The image type of this draw sequence */

    next:          *GPU_Atlas_Draw_Sequence; /**< The next sequence (will be NULL in case of the last sequence) */
}

Image_Type :: enum u32 {
    INVALID;
    ALPHA;   /**< The color channels are white */
    COLOR;   /**< The color channels have image data */
    SDF;     /**< The alpha channel has signed distance field information */
}

Text :: struct {
    text:      *u8;
    num_lines: s32;
    refcount:  s32;
    internal:  *Text_Data;
}

Text_Data :: void;

Text_Engine :: struct {
    version:      u32;
    userdata:     *void;

    create_text:  #type (userdata: *void, text: *Text) -> bool;
    destroy_text: #type (userdata: *void, text: *Text) -> void;
}


close_font              :: (font: *Font)                                                          #foreign SDL3_ttf "TTF_CloseFont";
create_gpu_text_engine  :: (device: *GPU_Device) -> *Text_Engine                                  #foreign SDL3_ttf "TTF_CreateGPUTextEngine";
create_text             :: (engine: *Text_Engine, font: *Font, text: *u8, length: u64) -> *Text   #foreign SDL3_ttf "TTF_CreateText";
destroy_gpu_text_engine :: (engine: *Text_Engine)                                                 #foreign SDL3_ttf "TTF_DestroyGPUTextEngine";
destroy_text            :: (text: *Text)                                                          #foreign SDL3_ttf "TTF_DestroyText";
get_gpu_text_draw_data  :: (text: *Text) -> *GPU_Atlas_Draw_Sequence                              #foreign SDL3_ttf "TTF_GetGPUTextDrawData";
init                    :: () -> bool                                                             #foreign SDL3_ttf "TTF_Init";
open_font               :: (file: *u8, ptsize: float) -> *Font                                    #foreign SDL3_ttf "TTF_OpenFont";
render_glyph_lcd        :: (font: *Font, ch: u32, fg: Color, bg: Color) -> *Surface               #foreign SDL3_ttf "TTF_RenderGlyph_LCD";
set_font_sdf            :: (font: *Font, enabled: bool) -> bool                                   #foreign SDL3_ttf "TTF_SetFontSDF";
quit                    :: () -> bool                                                             #foreign SDL3_ttf "TTF_Quit";


#scope_module;
#import "SDL3";