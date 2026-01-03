/*
TODO

- [x] What do we do with the renderer fields if we want to draw text or UI in the future where draw call sequences matter?
- [x] Review the entire flow for draw triangles again
- [ ] Figure out why the lettuce have white background
- [ ] How to keep aspect ratio when window is resized
- [x] How to do a 2D camera with pan/zoom (WASD + mouse wheel)
- [ ] Proper window resize handling
- [ ] How to display a large background (but not a tilemap)
- [ ] How to render to texture
- [x] Implement render_rect
- [x] Implement render_fill_rect
- [ ] Implement basic text rendering
- [ ] Implement scissor
- [ ] Implement DrawLineEX (using triangles/quads with thickness)
- [ ] Implement DrawLineBezier
- [ ] Implement DrawCircle (filled)
- [ ] Implement DrawCircleLines (circle outline)
- [ ] Implement DrawCircleLinesV(circle vector)
- [ ] Implement DrawEllipse
- [ ] Implement DrawEllipseLines
- [ ] Implement DrawPolyLines / DrawPolyLinesEx
- [ ] Implement DrawRectangleRounded / DrawRectangleRoundedLines / DrawRectangleRoundedLinesEx
- [ ] Implement basic physics and shape collisions
- [ ] Implement framerate and fixed timesteps

*/


#import "Basic";
#import "File";
#import "Math";
#import "String";
sdl :: #import "SDL3";
img :: #import "SDL3/image";

#load "asset.jai";
#load "gfx.jai";
#load "image.jai";
#load "matrix.jai";
#load "shader.jai";

WINDOW_WIDTH  :: 1920;
WINDOW_HEIGHT :: 1080;

CAMERA_PAN_SPEED :: 300.0;  // pixels per second
CAMERA_ZOOM_SPEED :: 0.1;   // zoom change per scroll tick

base_path: string;
use_camera: bool; // Toggle with SPACE key

main :: () {
    if !sdl.init(sdl.Init_Flags.VIDEO) {
        log_error("Could not initialize SDL: %\n", to_string(sdl.get_error()));
        return;
    }

    renderer: Renderer;
    renderer.device = sdl.create_gpu_device(
        sdl.GPU_Shader_Format.SPIRV | sdl.GPU_Shader_Format.DXIL | sdl.GPU_Shader_Format.MSL,
        true, null
    );
    if !renderer.device {
        log_error("SDL_CreateDevice failed: %\n", to_string(sdl.get_error()));
        return;
    }

    renderer.window = sdl.create_window("SDL3 GPU in Jai", WINDOW_WIDTH, WINDOW_HEIGHT, sdl.Window_Flags.RESIZABLE);
    if !renderer.window {
        log_error("Could not create window: %\n", to_string(sdl.get_error()));
        return;
    }

    if !sdl.claim_window_for_gpu_device(renderer.device, renderer.window) {
        log_error("SDL_ClaimWindowForGPUDevice failed: %\n", to_string(sdl.get_error()));
        return;
    }

    initialize_asset_loader();

    vertex_shader := load_shader(renderer.device, "assets/shaders/basic2d.vert", 0, 1, 0, 0);
    if !vertex_shader {
        log_error("Failed to create vertex shader\n");
        return;
    }

    fragment_shader := load_shader(renderer.device, "assets/shaders/basic2d.frag", 1, 0, 0, 0);
    if !fragment_shader {
        log_error("Failed to create fragment shader\n");
        return;
    }

    vertex_buffer_desc: sdl.GPU_Vertex_Buffer_Description;
    vertex_buffer_desc.pitch = size_of(Vertex_Data);
    vertex_buffer_desc.input_rate = .VERTEX;

    vertex_attributes: [3]sdl.GPU_Vertex_Attribute = .[
        {location = 0, buffer_slot = 0, format = .FLOAT3, offset = 0},
        {location = 1, buffer_slot = 0, format = .FLOAT4, offset = size_of(Vector3)},
        {location = 2, buffer_slot = 0, format = .FLOAT2, offset = size_of(Vector3) + size_of(Vector4)}
    ];

    vertex_input_state: sdl.GPU_Vertex_Input_State;
    vertex_input_state.num_vertex_buffers = 1;
    vertex_input_state.vertex_buffer_descriptions = *vertex_buffer_desc;
    vertex_input_state.num_vertex_attributes = vertex_attributes.count;
    vertex_input_state.vertex_attributes = vertex_attributes.data;

    renderer.quad_pipeline = create_pipeline(renderer.device, renderer.window, vertex_shader, fragment_shader, vertex_input_state, .TRIANGLELIST, enable_blend=true);
    if !renderer.quad_pipeline {
        log_error("Failed to create triangle pipeline\n");
        return;
    }

    renderer.line_pipeline = create_pipeline(renderer.device, renderer.window, vertex_shader, fragment_shader, vertex_input_state, .LINELIST);
    if !renderer.line_pipeline {
        log_error("Failed to create line pipeline\n");
        return;
    }

    sdl.release_gpu_shader(renderer.device, vertex_shader);
    sdl.release_gpu_shader(renderer.device, fragment_shader);

    renderer.sampler = create_sampler(renderer.device);
    renderer.max_sprites_per_batch = 1000;
    renderer.max_lines_per_batch = 1000;

    renderer.quad_vertex_buffer = create_gpu_buffer(renderer.device, .VERTEX, cast(u32)(size_of(Vertex_Data) * renderer.max_sprites_per_batch * 4), "Vertex Buffer");
    renderer.quad_index_buffer = create_gpu_buffer(renderer.device, .INDEX, cast(u32)(size_of(u16) * renderer.max_sprites_per_batch * 6), "Index Buffer");
    renderer.line_vertex_buffer = create_gpu_buffer(renderer.device, .VERTEX, cast(u32)(size_of(Vertex_Data) * renderer.max_lines_per_batch * 2), "Line Vertex Buffer");

    quad_transfer_buffer_info: sdl.GPU_Transfer_Buffer_Create_Info;
    quad_transfer_buffer_info.usage = .UPLOAD;
    quad_transfer_buffer_info.size = cast(u32)(size_of(Vertex_Data) * renderer.max_sprites_per_batch * 4 + size_of(u16) * renderer.max_sprites_per_batch * 6);
    renderer.quad_transfer_buffer = sdl.create_gpu_transfer_buffer(renderer.device, *quad_transfer_buffer_info);

    line_transfer_buffer_info: sdl.GPU_Transfer_Buffer_Create_Info;
    line_transfer_buffer_info.usage = .UPLOAD;
    line_transfer_buffer_info.size = cast(u32)(size_of(Vertex_Data) * renderer.max_lines_per_batch * 2);
    renderer.line_transfer_buffer = sdl.create_gpu_transfer_buffer(renderer.device, *line_transfer_buffer_info);

    drawable_width, drawable_height: s32;
    sdl.get_window_size_in_pixels(renderer.window, *drawable_width, *drawable_height);
    renderer.projection = orthographic_projection_matrix(
        left = 0,
        right = drawable_width.(float),
        bottom = drawable_height.(float),
        top = 0,
        near = 0,
        far = 1,
    );

    // Initialize camera at origin with 1.0 zoom
    camera := create_camera();
    camera.offset = {0, 0};

    renderer.white_texture = create_white_texture(*renderer);
    if renderer.white_texture == null {
        log_error("Failed to create white texture for renderer: %\n", to_string(sdl.get_error()));
        return;
    }

    lettuce_texture := load_texture(*renderer, "assets/images/lettuce.bmp");
    if !lettuce_texture {
        log_error("Failed to load lettuce texture\n");
        return;
    }
    bg_texture := load_texture(*renderer, "assets/images/bg.jpg");
    if !bg_texture {
        log_error("Failed to load bg texture\n");
        return;
    }

    exit := false;
    last_time := sdl.get_ticks_ns();

    while !exit {
        current_time := sdl.get_ticks_ns();
        delta_time := cast(float)(current_time - last_time) / 1_000_000_000.0;  // Convert to seconds
        last_time = current_time;

        event: sdl.Event;
        while sdl.poll_event(*event) {
            if event.type == {
                case .QUIT; exit = true;
                case .KEY_UP;
                    if event.key.key == .ESCAPE exit = true;
                    if event.key.key == .SPACE use_camera = !use_camera;
                case .WINDOW_RESIZED;
                case .WINDOW_PIXEL_SIZE_CHANGED;
                    drawable_width, drawable_height: s32;
                    sdl.get_window_size_in_pixels(renderer.window, *drawable_width, *drawable_height);
                    renderer.projection = orthographic_projection_matrix(
                        left = 0,
                        right = drawable_width.(float),
                        bottom = drawable_height.(float),
                        top = 0,
                        near = 0,
                        far = 1,
                    );
                case .MOUSE_WHEEL;
                    if use_camera {
                        // Zoom with mouse wheel
                        zoom_delta := event.wheel.y * CAMERA_ZOOM_SPEED;
                        camera.zoom += zoom_delta;
                        // Clamp zoom to reasonable values
                        if camera.zoom < 0.1 camera.zoom = 0.1;
                        if camera.zoom > 5.0 camera.zoom = 5.0;
                    }
            }
        }

        // Camera pan with WASD
        if use_camera {
            num_keys: s32;
            keyboard_state := sdl.get_keyboard_state(*num_keys);
            if keyboard_state[sdl.Scancode.W] camera.target.y -= cast(float32)(CAMERA_PAN_SPEED * delta_time);
            if keyboard_state[sdl.Scancode.S] camera.target.y += cast(float32)(CAMERA_PAN_SPEED * delta_time);
            if keyboard_state[sdl.Scancode.A] camera.target.x -= cast(float32)(CAMERA_PAN_SPEED * delta_time);
            if keyboard_state[sdl.Scancode.D] camera.target.x += cast(float32)(CAMERA_PAN_SPEED * delta_time);
        }

        if !begin_frame(*renderer) {
            log_error("Failed to begin frame\n");
            return;
        }

        begin_camera_mode(*renderer, *camera);

        // Draw bg
        bg_src_rect := sdl.F_Rect.{0, 0, cast(float)bg_texture.width, cast(float)bg_texture.height};
        render_texture(*renderer, bg_texture, *bg_src_rect, null);

        large_line_rect := sdl.F_Rect.{100, 100, 700, 700};
        large_line_color := sdl.Color.{0, 255, 0, 255};
        render_rect(*renderer, *large_line_rect, *large_line_color);

        // Draw multiple lettuces at different positions
        lettuce_src_rect := sdl.F_Rect.{0, 0, cast(float)lettuce_texture.width, cast(float)lettuce_texture.height};

        dst1 := sdl.F_Rect.{0, 0, 150, 150};
        render_texture(*renderer, lettuce_texture, *lettuce_src_rect, *dst1);

        dst2 := sdl.F_Rect.{150, 150, 200, 200};
        render_texture(*renderer, lettuce_texture, *lettuce_src_rect, *dst2);

        dst3 := sdl.F_Rect.{350, 350, 100, 100};
        render_texture(*renderer, lettuce_texture, *lettuce_src_rect, *dst3);

        dst4 := sdl.F_Rect.{450, 450, 180, 180};
        render_texture(*renderer, lettuce_texture, *lettuce_src_rect, *dst4);

        rect := sdl.F_Rect.{600, 600, 200, 200};
        color := sdl.Color.{0, 255, 0, 255};
        render_fill_rect(*renderer, *rect, *color);

        line_rect := sdl.F_Rect.{1000, 500, 200, 200};
        line_color := sdl.Color.{0, 255, 0, 255};
        render_rect(*renderer, *line_rect, *line_color);

        end_camera_mode(*renderer);

        end_frame(*renderer);
    }

    sdl.release_gpu_transfer_buffer(renderer.device, renderer.quad_transfer_buffer);
    sdl.release_gpu_transfer_buffer(renderer.device, renderer.line_transfer_buffer);
    sdl.release_gpu_buffer(renderer.device, renderer.quad_vertex_buffer);
    sdl.release_gpu_buffer(renderer.device, renderer.quad_index_buffer);
    sdl.release_gpu_buffer(renderer.device, renderer.line_vertex_buffer);
    sdl.release_gpu_graphics_pipeline(renderer.device, renderer.quad_pipeline);
    sdl.release_gpu_graphics_pipeline(renderer.device, renderer.line_pipeline);
    sdl.release_gpu_sampler(renderer.device, renderer.sampler);
    sdl.destroy_gpu_device(renderer.device);

    sdl.destroy_window(renderer.window);
    sdl.quit();
}
