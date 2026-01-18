/*
TODO

- [x] What do we do with the renderer fields if we want to draw text or UI in the future where draw call sequences matter?
- [x] Review the entire flow for draw triangles again
- [ ] Figure out why the lettuce have white background
- [ ] How to keep aspect ratio when window is resized
- [x] How to do a 2D camera with pan/zoom (WASD + mouse wheel)
- [ ] Proper window resize handling
- [ ] How to display a large background (but not a tilemap)
- [ ] How to render to texture with a fixed internal resolution (for pixel art)
- [ ] Set target FPS
- [x] Implement render_rect
- [x] Implement render_fill_rect
- [x] Implement basic text rendering
- [ ] Figure out how to handle text rendering in screen space vs UI vs quad rendering in game viewport space
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
ttf :: #import "SDL3/ttf";

#load "asset.jai";
#load "gfx.jai";
#load "image.jai";
#load "matrix.jai";
#load "shader.jai";
#load "time.jai";

WINDOW_WIDTH  :: 1920;
WINDOW_HEIGHT :: 1080;

CAMERA_PAN_SPEED :: 300.0;  // pixels per second
CAMERA_ZOOM_SPEED :: 0.1;   // zoom change per scroll tick

base_path: string;

use_camera: bool; // Toggle with SPACE key

main :: () {
    initialize_asset_loader();

    renderer, ok := renderer_init(WINDOW_WIDTH, WINDOW_HEIGHT, "SDL3 GPU in Jai", use_viewport=true);
    if !ok return;

    // Initialize camera at origin with 1.0 zoom
    camera := create_camera();
    camera.offset = {0, 0};

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

    font_small = ttf.open_font("assets/fonts/smallburg-regular.ttf", 48.0);
    if !font_small {
        log_error("Failed to load font: %\n", to_string(sdl.get_error()));
        return;
    }
    font_large = ttf.open_font("assets/fonts/smallburg-regular.ttf", 96.0);
    if !font_large {
        log_error("Failed to load font: %\n", to_string(sdl.get_error()));
        return;
    }

    text_small := ttf.create_text(renderer.text_engine, font_small, "Hello, SDL3!", 0);
    if !text_small {
        log_error("Failed to create text: %\n", to_string(sdl.get_error()));
        return;
    }
    text_large := ttf.create_text(renderer.text_engine, font_large, "Hello, SDL3!", 0);
    if !text_large {
        log_error("Failed to create text: %\n", to_string(sdl.get_error()));
        return;
    }


    time_init();
    set_target_fps(60);

    angle := 0.0; // @TODO: debug/test

    exit := false;
    while !exit {
        dt = get_frame_time();

        event: sdl.Event;
        while sdl.poll_event(*event) {
            if event.type == {
                case .QUIT; exit = true;
                case .KEY_UP;
                    if event.key.key == .ESCAPE exit = true;
                    if event.key.key == .SPACE use_camera = !use_camera;
                case .WINDOW_RESIZED;
                case .WINDOW_PIXEL_SIZE_CHANGED;
                    // The projection matrix stays fixed at target resolution; the viewport handles the aspect ratio
                    drawable_width, drawable_height: s32;
                    sdl.get_window_size_in_pixels(renderer.window, *drawable_width, *drawable_height);
                    if renderer.use_viewport {
                        set_viewport(*renderer, drawable_width, drawable_height);
                    } else {
                        renderer.projection = orthographic_projection_matrix(
                            left = 0,
                            right = drawable_width.(float),
                            bottom = drawable_height.(float),
                            top = 0,
                            near = 0,
                            far = 1,
                        );
                    }
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
            if keyboard_state[sdl.Scancode.W] camera.target.y -= cast(float32)(CAMERA_PAN_SPEED * dt);
            if keyboard_state[sdl.Scancode.S] camera.target.y += cast(float32)(CAMERA_PAN_SPEED * dt);
            if keyboard_state[sdl.Scancode.A] camera.target.x -= cast(float32)(CAMERA_PAN_SPEED * dt);
            if keyboard_state[sdl.Scancode.D] camera.target.x += cast(float32)(CAMERA_PAN_SPEED * dt);
        }

        if !begin_frame(*renderer) {
            log_error("Failed to begin frame\n");
            return;
        }

        // Set camera for this entire frame (or null for screen space)
        if use_camera {
            set_camera(*renderer, *camera);
        } else {
            set_camera(*renderer, null);
        }

        drawing_stuff(*renderer, bg_texture, lettuce_texture, *angle, dt);
        draw_text(*renderer, text_small, text_large);

        end_frame(*renderer);
    }

    renderer_shutdown(*renderer);

    // @TODO: Move this somewhere else
    ttf.destroy_text(text_small);
    ttf.destroy_text(text_large);
    ttf.close_font(font_small);
    ttf.close_font(font_large);
    ttf.destroy_gpu_text_engine(renderer.text_engine);
    ttf.quit();
}

drawing_stuff :: (renderer: *Renderer, bg_texture: *Texture, lettuce_texture: *Texture, angle: *float32, dt: float32) {
    // Draw bg
    bg_src_rect := sdl.F_Rect.{0, 0, cast(float)bg_texture.width, cast(float)bg_texture.height};
    render_texture(renderer, bg_texture, *bg_src_rect, null);

    large_line_rect := sdl.F_Rect.{50, 50, 300, 250};  // Scaled down, fits in viewport
    large_line_color := sdl.Color.{0, 255, 0, 255};
    render_rect(renderer, *large_line_rect, *large_line_color);

    // Draw multiple lettuces at different positions
    lettuce_src_rect := sdl.F_Rect.{0, 0, cast(float)lettuce_texture.width, cast(float)lettuce_texture.height};

    dst1 := sdl.F_Rect.{0, 0, 80, 80};
    render_texture(renderer, lettuce_texture, *lettuce_src_rect, *dst1);

    dst2 := sdl.F_Rect.{90, 90, 100, 100};
    render_texture(renderer, lettuce_texture, *lettuce_src_rect, *dst2);

    dst3 := sdl.F_Rect.{200, 200, 60, 60};
    origin := Vector2.{dst3.w / 2, dst3.h / 2};
    angle.* += 50 * dt;
    render_texture(renderer, lettuce_texture, *lettuce_src_rect, *dst3, origin, rotation = angle.* * PI / 180.0);

    dst4 := sdl.F_Rect.{270, 270, 90, 90};
    render_texture(renderer, lettuce_texture, *lettuce_src_rect, *dst4);

    rect := sdl.F_Rect.{400, 200, 100, 100};  // Moved to fit
    color := sdl.Color.{0, 255, 0, 255};
    fill_rect_origin := Vector2.{rect.w / 2, rect.h / 2};
    render_fill_rect(renderer, *rect, *color, fill_rect_origin, rotation = angle.* * PI / 180.0);

    line_rect := sdl.F_Rect.{450, 50, 150, 150};  // Moved to fit in 640x360
    line_color := sdl.Color.{0, 255, 0, 255};
    rect_origin := Vector2.{line_rect.w / 2, line_rect.h / 2};
    render_rect(renderer, *line_rect, *line_color, rect_origin, rotation = angle.* * PI / 180.0);
}

draw_text :: (renderer: *Renderer, text1: *ttf.Text, text2: *ttf.Text) {
    text_color := Vector4.{1, 1, 0, 1};

    text_position := Vector2.{0, 0};
    text_sequence := ttf.get_gpu_text_draw_data(text1);
    queue_text(renderer, text_sequence, text_position, text_color);

    text_position2 := Vector2.{50, 50};
    text_sequence2 := ttf.get_gpu_text_draw_data(text2);
    queue_text(renderer, text_sequence2, text_position2, text_color);
}
