#import "Basic";
#import "File";
#import "Math";
#import "String";
#import "Windows";
sdl :: #import "SDL3";
img :: #import "SDL3/image";

#load "asset.jai";
#load "shader.jai";

DEBUG         :: 1;
WINDOW_WIDTH  :: 800;
WINDOW_HEIGHT :: 600;

base_path: string;
device:    *sdl.GPU_Device;
renderer:  *sdl.Renderer;
window:    *sdl.Window;
hwnd:      *void;

main :: () {
    if !sdl.init(sdl.Init_Flags.VIDEO) {
        log_error("Could not initialize SDL: %\n", to_string(sdl.get_error()));
        return;
    }

    device = sdl.create_gpu_device(
        sdl.GPU_Shader_Format.SPIRV | sdl.GPU_Shader_Format.DXIL | sdl.GPU_Shader_Format.MSL,
        true,
        null,
    );
    if device == null {
        log_error("SDL_CreateDevice failed: %\n", to_string(sdl.get_error()));
        return;
    }

    window = sdl.create_window(
        "SDL3 GPU in Jai",
        WINDOW_WIDTH, WINDOW_HEIGHT,
        sdl.Window_Flags.RESIZABLE,
    );
    if window == null {
        log_error("Could not create window: %\n", to_string(sdl.get_error()));
        sdl.quit();
        return;
    }

    if !sdl.claim_window_for_gpu_device(device, window) {
        log_error("SDL_ClaimWindowForGPUDevice failed: %\n", to_string(sdl.get_error()));
        return;
    }

    initialize_asset_loader();

    vertex_shader_path := "assets/shaders/RawTriangle.vert";
    vertex_shader := load_shader(device, vertex_shader_path, 0, 0, 0, 0);
    if vertex_shader == null {
        log_error("Failed to create vertex shader\n");
        return;
    }

    fragment_shader_path := "assets/shaders/SolidColor.frag";
    fragment_shader := load_shader(device, fragment_shader_path, 0, 0, 0, 0);
    if fragment_shader == null {
        log_error("Failed to create fragment shader\n");
        return;
    }

    color_target_descriptions: sdl.GPU_Color_Target_Description;
    color_target_descriptions.format = sdl.get_gpu_swapchain_texture_format(device, window);

    pipeline_create_info: sdl.GPU_Graphics_Pipeline_Create_Info;
    pipeline_create_info.vertex_shader              = vertex_shader;
    pipeline_create_info.fragment_shader            = fragment_shader;
    pipeline_create_info.rasterizer_state.fill_mode = sdl.GPU_Fill_Mode.FILL;
    pipeline_create_info.primitive_type             = sdl.GPU_Primitive_Type.TRIANGLELIST;
    pipeline_create_info.target_info                = sdl.GPU_Graphics_Pipeline_Target_Info.{
        num_color_targets         = 1,
        color_target_descriptions = *color_target_descriptions,
    };

    pipeline: *sdl.GPU_Graphics_Pipeline;
    pipeline = sdl.create_gpu_graphics_pipeline(device, *pipeline_create_info);
    if pipeline == null {
        log_error("Failed to create fill pipeline\n");
        return;
    }
    sdl.release_gpu_shader(device, vertex_shader);
    sdl.release_gpu_shader(device, fragment_shader);

    /*
    * Main loop
    */
    exit := false;
    while !exit {
        event: sdl.Event;
        while sdl.poll_event(*event) {
            if event.type == {
                case sdl.Event_Type.QUIT;
                    exit = true;
                case sdl.Event_Type.KEY_UP;
                    if event.key.key == sdl.Keycode.ESCAPE exit = true;
            }
        }

        cmdbuf := sdl.acquire_gpu_command_buffer(device);
        if cmdbuf == null {
            log_error("SDL_AcquireGPUCommandBuffer failed: %\n", to_string(sdl.get_error()));
            return;
        }

        swapchain_texture: *sdl.GPU_Texture;
        acquired := sdl.wait_and_acquire_gpu_swapchain_texture(cmdbuf, window, *swapchain_texture, null, null);
        assert(acquired);
        if swapchain_texture != null {
            color_target_info: sdl.GPU_Color_Target_Info;
            color_target_info.texture     = swapchain_texture;
            color_target_info.clear_color = sdl.F_Color.{0.3, 0.6, 0.5, 1.0};
            color_target_info.load_op     = sdl.GPU_Load_Op.CLEAR;
            color_target_info.store_op    = sdl.GPU_Store_Op.STORE;

            render_pass := sdl.begin_gpu_render_pass(cmdbuf, *color_target_info, 1, null);

            sdl.bind_gpu_graphics_pipeline(render_pass, pipeline);
            sdl.draw_gpu_primitives(render_pass, 3, 1, 0, 0);

            sdl.end_gpu_render_pass(render_pass);
        }

        sdl.submit_gpu_command_buffer(cmdbuf);
    }

    sdl.release_gpu_graphics_pipeline(device, pipeline);
    sdl.destroy_window(window);
    sdl.quit();

    return;
}
