#load "SDL_ttf.jai";

#scope_export

// #if OS == .LINUX
// {
//     X11 :: #import "X11";
//     SDL3_ttf :: #library "linux/libSDL3_ttf";
//     #library,system,link_always "libdl";
//     #library,system,link_always "libm";
//     #library,system,link_always "libpthread";
// }
#if OS == .WINDOWS {
    SDL3_ttf :: #library "windows/SDL3_ttf";
} else #if OS == .MACOS {
    SDL3_ttf :: #library "macos/libSDL3_ttf";
    #library,system,link_always "libdl";
    #library,system,link_always "libm";
}
