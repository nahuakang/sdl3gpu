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

    compiler_end_intercept(w);
    set_build_options_dc(.{do_output=false});
}

#run build();