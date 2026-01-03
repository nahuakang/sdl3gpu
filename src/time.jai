current_time: u64;
draw_time: u64;
frame_time: u64;
update_time: u64;
previous_time: u64;
target_time: u64;
wait_time: u64;
dt: float32;

set_target_fps :: (fps: u64) {
    target_time = 1000 / fps;
}

// Get time in seconds for last frame drawn a.k.a. delta time
get_frame_time :: () -> float32 {
    return frame_time / 1000.0;
}

time_init :: () {
    previous_time = sdl.get_ticks();
}

time_begin_frame :: () {
    current_time = sdl.get_ticks();
    update_time = current_time - previous_time;
    previous_time = current_time;
}

time_end_frame :: () {
    current_time = sdl.get_ticks();
    draw_time = current_time - previous_time;
    previous_time = current_time;
    frame_time = update_time + draw_time; // Update frame time

    if frame_time < target_time {
        sdl.delay(xx (target_time - frame_time));
        current_time = sdl.get_ticks();
        wait_time = current_time - previous_time;
        frame_time += wait_time; // Total frame time = update + draw + wait
    }
}
