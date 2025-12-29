Font :: void;

close_font       :: (font: *Font)                                                     #foreign SDL3_ttf "TTF_CloseFont";
init             :: () -> bool                                                        #foreign SDL3_ttf "TTF_Init";
open_font        :: (file: *u8, ptsize: float) -> *Font                               #foreign SDL3_ttf "TTF_OpenFont";
render_glyph_lcd :: (font: *Font, ch: u32, fg: Color, bg: Color) -> *Surface          #foreign SDL3_ttf "TTF_RenderGlyph_LCD";
quit             :: () -> bool                                                        #foreign SDL3_ttf "TTF_Quit";


#scope_module;
#import "SDL3";