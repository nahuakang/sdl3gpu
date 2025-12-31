#import "Basic";
#import "Compiler";
#import "File";
#import "File_Utilities";
#import "Process";

build :: () {
    w := compiler_create_workspace("SDL3 GPU");
    if !w {
        log("Workspace creation failed.\n");
        return;
    }

    options := get_build_options(w);
    options.output_path = "build";
    make_directory_if_it_does_not_exist(options.output_path);
    options.output_executable_name = "sdl3gpu";

    set_build_options(options, w);

    compiler_begin_intercept(w);
    add_build_file("src/main.jai", w);

    while true {
        message := compiler_wait_for_message();
        if !message break;
        if message.workspace != w continue;  // Only process messages for our workspace

        if message.kind == .COMPLETE {
            complete := cast(*Message_Complete) message;
            if complete.error_code == .NONE {
                // Compilation succeeded, now patch the binary on macOS
                #if OS == .MACOS {
                    // copy_file("modules/SDL3/macos/libSDL3.dylib", "build/libSDL3.dylib");
                    // copy_file("modules/SDL3/image/macos/libSDL3_image.dylib", "build/libSDL3_image.dylib");

                    run_command("install_name_tool", "-change", "@rpath/SDL3.framework/Versions/A/SDL3", "@rpath/libSDL3.dylib", "build/sdl3gpu");
                    run_command("install_name_tool", "-change", "@rpath/SDL3_image.framework/Versions/A/SDL3_image", "@rpath/libSDL3_image.dylib", "build/sdl3gpu");
                }
            }
            break;  // Exit after compilation completes
        }
    }

    compiler_end_intercept(w);
    set_build_options_dc(.{do_output=false});
}

#run build();