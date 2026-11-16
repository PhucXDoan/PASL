package main



main :: proc() {



    // Raylib initializations.

    raylib.SetTraceLogLevel(.WARNING)

    WINDOW_DIMENSION_PX :: 800

    raylib.InitWindow(
        width  = WINDOW_DIMENSION_PX,
        height = WINDOW_DIMENSION_PX,
        title  = "PASL",
    )
    defer raylib.CloseWindow()

    raylib.SetTargetFPS(raylib.GetMonitorRefreshRate(raylib.GetCurrentMonitor()))
    raylib.SetExitKey(nil)

    {
        icon := raylib.LoadImage("./icon.png")
        defer raylib.UnloadImage(icon)
        raylib.SetWindowIcon(icon)
    }



    // MicroUI initializations.

    @(static)
    microui_context       : microui.Context
    microui_atlas_texture : raylib.Texture

    microui.init(&microui_context)
    microui_context.text_width  = microui.default_atlas_text_width
    microui_context.text_height = microui.default_atlas_text_height

    @(static)
    microui_atlas_pixels : [microui.DEFAULT_ATLAS_WIDTH * microui.DEFAULT_ATLAS_HEIGHT][2]u8
    for alpha, index in microui.default_atlas_alpha {
        microui_atlas_pixels[index] = { 0xFF, alpha }
    }

    microui_atlas_texture = raylib.LoadTextureFromImage({
        data    = raw_data(microui_atlas_pixels[:]),
        width   = microui.DEFAULT_ATLAS_WIDTH,
        height  = microui.DEFAULT_ATLAS_HEIGHT,
        mipmaps = 1,
        format  = .UNCOMPRESSED_GRAY_ALPHA,
    })



    // Assets.

    sprite_texture := raylib.LoadTexture("sprite.png")
    defer raylib.UnloadTexture(sprite_texture)

    SPRITES_PER_ROW            :: 8
    sprite_source_dimension_px := f32(sprite_texture.width) / SPRITES_PER_ROW

    @(static)
    font : raylib.Font

    FONT_SIZE :: 100

    font = raylib.LoadFontEx(
        fileName       = "./SpaceMono-Bold.ttf",
        fontSize       = FONT_SIZE,
        codepoints     = nil,
        codepointCount = 0,
    )

    ASL_Sign :: enum {
        A, B, C, D, E, F, G, H, I, J, K, L, M,
        N, O, P, Q, R, S, T, U, V, W, X, Y, Z,
    }

    ASL_Sign_Statistic :: struct {
        total_duration  : time.Duration,
        total_attempts  : int,
        first_try_count : int,
    }

    STATISTICS_JSON_FILE_PATH :: "./statistics.json"

    statistics : [ASL_Sign]ASL_Sign_Statistic

    loading_specification_json_file: {

        json_file_content, reading_error := os.read_entire_file(
            name      = STATISTICS_JSON_FILE_PATH,
            allocator = context.temp_allocator,
        )

        if reading_error != nil {
            break loading_specification_json_file
        }

        json.unmarshal(
            data      = json_file_content,
            ptr       = &statistics,
            spec      = .JSON5,
            allocator = context.allocator,
        ) or_else panic("Failed.")

    }

    score_of_statistic :: proc(statistic : ASL_Sign_Statistic, same_as_previous_sign : bool) -> f64 {
        return (
            + (f64(statistic.first_try_count) / f64(statistic.total_attempts)) * 5000 // Accuracy.
            + 1 / (time.duration_seconds(statistic.total_duration) + 0.1)      * 100  // Reaction time.
            + f64(statistic.total_attempts)                                    * 5    // Frequency.
            + (300 if same_as_previous_sign else 0)                                   // Artifically increase score to make showing the same again sign less likely.
        ) if statistic.total_attempts >= 1 else 0
    }



    // General program state data.

    program :  Program
    Program :: struct {
        sign_shown_timestamp  : time.Time,
        displayed_sign        : ASL_Sign,
        displayed_rotation    : Spline(f32),
        displayed_scale       : Spline(f32),
        displayed_mirrored    : bool,
        displayed_tint        : Spline(raylib.Color),
        made_a_mistake        : bool,
        border_color          : Spline(raylib.Color),
        outlier               : bool,
        user_input_text       : [32]u8,
        user_input_text_color : Spline(raylib.Color),
        stun_time_remaining   : time.Duration,
    }



    // Update loop.

    for !raylib.WindowShouldClose() {

        current_timestamp := time.now()
        frame_delta_time  := raylib.GetFrameTime()
        mouse_position    := raylib.GetMousePosition()
        mouse_scroll      := raylib.GetMouseWheelMove()



        // Update MicroUI with user inputs.

        {



            // User's typing input.

            {

                buffer  :  [512]u8
                builder := strings.builder_from_bytes(buffer[:])

                for {

                    character := raylib.GetCharPressed()

                    if character == '\x00' {
                        break
                    }

                    strings.write_rune(&builder, character)

                }

                microui.input_text(&microui_context, strings.to_string(builder))

            }



            // User's keyboard input.

            for raylib_key, microui_key in ([microui.Key]raylib.KeyboardKey {
                .SHIFT     = .LEFT_SHIFT,
                .CTRL      = .LEFT_CONTROL,
                .ALT       = .LEFT_ALT,
                .BACKSPACE = .BACKSPACE,
                .DELETE    = .DELETE,
                .RETURN    = .ENTER,
                .LEFT      = .LEFT,
                .RIGHT     = .RIGHT,
                .HOME      = .HOME,
                .END       = .END,
                .A         = .A,
                .X         = .X,
                .C         = .C,
                .V         = .V,
            }) {

                if raylib.IsKeyPressed(raylib_key) {
                    microui.input_key_down(&microui_context, microui_key)
                }

                if raylib.IsKeyReleased(raylib_key) {
                    microui.input_key_up(&microui_context, microui_key)
                }

            }



            // User's mouse input.

            microui.input_scroll(
                &microui_context,
                0,
                i32(mouse_scroll * -30), // Adjust for sensitivity.
            )

            microui.input_mouse_move(
                &microui_context,
                i32(mouse_position.x),
                i32(mouse_position.y),
            )

            for raylib_mouse, microui_mouse in ([microui.Mouse]raylib.MouseButton {
                .LEFT   = .LEFT,
                .MIDDLE = .MIDDLE,
                .RIGHT  = .RIGHT,
            }) {

                if raylib.IsMouseButtonPressed(raylib_mouse) {

                    microui.input_mouse_down(
                        &microui_context,
                        i32(mouse_position.x),
                        i32(mouse_position.y),
                        microui_mouse,
                    )

                }

                if raylib.IsMouseButtonReleased(raylib_mouse) {

                    microui.input_mouse_up(
                        &microui_context,
                        i32(mouse_position.x),
                        i32(mouse_position.y),
                        microui_mouse,
                    )

                }

            }



        }



        // We'll be determining if the displayed sign needs to be re-randomized.
        // This would be done immediately upon program start-up.

        refresh_displayed_sign := false

        if program == {} {
            refresh_displayed_sign = true
        }



        // If it's taking too long to correctly input the sign, we consider it to be an outlier.

        sign_display_duration := time.diff(program.sign_shown_timestamp, current_timestamp)

        if time.duration_seconds(sign_display_duration) >= 5 {
            program.outlier = true
        }



        // Process the user's input.

        processing_key_presses: for {

            key := raylib.GetKeyPressed()

            #partial switch key {

                case .KEY_NULL: {
                    break processing_key_presses
                }

                case .ESCAPE: {
                    program.outlier                                          = true
                    microui.get_container(&microui_context, "Settings").open = true
                }

                case .A ..= .Z: {

                    if program.stun_time_remaining == 0 { // Make the user be in time-out for a bit before actually accepting any answer.

                        program.user_input_text[0] = 'A' + u8(key - .A)

                        if key == raylib.KeyboardKey.A + raylib.KeyboardKey(program.displayed_sign) {

                            if !program.outlier {
                                statistics[program.displayed_sign].total_duration  += sign_display_duration
                                statistics[program.displayed_sign].total_attempts  += 1
                                statistics[program.displayed_sign].first_try_count += 1 if !program.made_a_mistake else 0
                            }

                            refresh_displayed_sign        = true
                            program.made_a_mistake        = false
                            program.outlier               = false
                            program.border_color          = { raylib.GREEN, raylib.BLACK, -20 }
                            program.user_input_text_color = { raylib.GREEN, {}          , -3  }

                        } else {

                            program.made_a_mistake        = true
                            program.border_color          = { raylib.RED  , raylib.BLACK, -2 }
                            program.user_input_text_color = { raylib.RED  , {}          , -2 }
                            program.displayed_tint        = { raylib.WHITE, raylib.WHITE,  0 }
                            program.stun_time_remaining   = 2 * time.Second if !program.outlier else 0

                        }

                    }

                }

            }

        }



        // Randomize the displayed sign.

        if refresh_displayed_sign {



            // Sort all of the ASL signs by their score.
            // The signs with lower scores are more likely to be selected.

            sample_space :  [len(statistics)]Sample
            Sample       :: struct {
                sign  : ASL_Sign,
                score : f64,
            }

            for statistic, asl_sign in statistics {
                sample_space[asl_sign] = {
                    sign  = asl_sign,
                    score = score_of_statistic(statistic, asl_sign == program.displayed_sign)
                }
            }

            slice.sort_by(
                data = sample_space[:],
                less = proc(i, j : Sample) -> bool {
                    return i.score < j.score
                },
            )



            // Randomly select from the sample space with a geometric distribution.

            FIRST_PROBABILITY :: 0.2
            sample_index      := min(int(math.floor(math.ln(1 - rand.float64()) / math.ln(1 - FIRST_PROBABILITY))), len(sample_space) - 1)

            program.sign_shown_timestamp = time.now()
            program.displayed_sign       = sample_space[sample_index].sign

            program.displayed_rotation = {
                rand.float32_range(-30, 30),
                rand.float32_range(-30, 30),
                rand.float32_range(-5, 0),
            }

            program.displayed_scale = {
                rand.float32_range(0.8, 1.1),
                rand.float32_range(0.8, 1.1),
                rand.float32_range(-5, 0),
            }

            program.displayed_mirrored = rand.int_max(2) == 0

            program.displayed_tint = {
                {
                    u8(rand.int_range(100, 256)),
                    u8(rand.int_range(100, 256)),
                    u8(rand.int_range(100, 256)),
                    255,
                },
                {},
                rand.float32_range(-3, 0),
            }

        }



        // Indicate outlier state.

        if program.outlier {
            program.border_color.target   = raylib.YELLOW
            program.border_color.lambda   = -30
            program.displayed_tint.target = raylib.WHITE
            program.displayed_tint.lambda = -30
            program.stun_time_remaining   = 0
        }



        // Indicate stun state.

        was_stunned := program.stun_time_remaining >= 1

        program.stun_time_remaining -= time.Duration(frame_delta_time * f32(time.Second))
        program.stun_time_remaining  = max(program.stun_time_remaining, 0)

        got_out_of_being_stunned := was_stunned && (program.stun_time_remaining == 0)

        if got_out_of_being_stunned {

            program.border_color.target          = {}
            program.border_color.lambda          = -10
            program.user_input_text_color.target = {}
            program.user_input_text_color.lambda = -10

        } else if was_stunned {

            program.border_color.target          = raylib.ColorLerp({ 255, 0, 0, 255 }, { 100, 0, 0, 255 }, f32(math.sin(40 * time.duration_seconds(program.stun_time_remaining))))
            program.border_color.lambda          = -30
            program.user_input_text_color.target = program.border_color.target
            program.user_input_text_color.lambda = -30
            program.displayed_tint.target        = raylib.WHITE
            program.displayed_tint.lambda        = -30

        }



        // Interpolate stuff.

        spline_dampen(&program.border_color         , frame_delta_time)
        spline_dampen(&program.user_input_text_color, frame_delta_time)
        spline_dampen(&program.displayed_rotation   , frame_delta_time)
        spline_dampen(&program.displayed_scale      , frame_delta_time)
        spline_dampen(&program.displayed_tint       , frame_delta_time)



        // Settings UI.

        {

            microui.begin(&microui_context)
            defer microui.end(&microui_context)

            if microui.begin_window(
                &microui_context,
                "Settings",
                { 100, 100, 300, 200 },
                { .CLOSED }
            ) {

                defer microui.end_window(&microui_context)

                microui.layout_row(&microui_context, { -1, -1 }, 0)

                microui.label(&microui_context, "what is going on?")

                microui.button(&microui_context, "Button 1")

                if .ACTIVE in microui.treenode(&microui_context, "Test 1b") {
                    microui.button(&microui_context, "Button 1")
                    microui.button(&microui_context, "Button 2")
                }

            }

        }



        // Render.

        {

            raylib.BeginDrawing()
            defer raylib.EndDrawing()

            raylib.ClearBackground(raylib.BLACK)



            // Displayed sign.

            raylib.DrawTexturePro(
                texture = sprite_texture,
                srcrec  = {
                    x      = f32(int(program.displayed_sign) % SPRITES_PER_ROW) * sprite_source_dimension_px,
                    y      = f32(int(program.displayed_sign) / SPRITES_PER_ROW) * sprite_source_dimension_px,
                    width  = sprite_source_dimension_px * (-1 if program.displayed_mirrored else 1),
                    height = sprite_source_dimension_px,
                },
                dstrec = {
                    x      = WINDOW_DIMENSION_PX / 2,
                    y      = WINDOW_DIMENSION_PX / 2,
                    width  = WINDOW_DIMENSION_PX * program.displayed_scale.actual,
                    height = WINDOW_DIMENSION_PX * program.displayed_scale.actual,
                },
                origin   = {
                    WINDOW_DIMENSION_PX / 2,
                    WINDOW_DIMENSION_PX / 2,
                },
                rotation = program.displayed_rotation.actual,
                tint     = program.displayed_tint.actual,
            )



            // Border.

            raylib.DrawRectangleLinesEx(
                rec = {
                    x      = 0,
                    y      = 0,
                    width  = WINDOW_DIMENSION_PX,
                    height = WINDOW_DIMENSION_PX,
                },
                thick = 8,
                color = program.border_color.actual,
            )



            // User input echo.

            {

                program.user_input_text[len(program.user_input_text) - 1] = '\x00'

                spacing   := f32(FONT_SIZE / font.baseSize)
                text      := transmute(cstring) raw_data(program.user_input_text[:])
                position  := raylib.Vector2 {
                    WINDOW_DIMENSION_PX * 0.5,
                    WINDOW_DIMENSION_PX * 0.9,
                }

                text_measurement := raylib.MeasureTextEx(
                    font     = font,
                    text     = text,
                    fontSize = FONT_SIZE,
                    spacing  = spacing,
                )

                raylib.DrawTextPro(
                    font     = font,
                    text     = text,
                    position = position,
                    origin   = text_measurement / 2,
                    rotation = 0,
                    fontSize = FONT_SIZE,
                    spacing  = spacing,
                    tint     = program.user_input_text_color.actual,
                )

            }



            // MicroUI.

            {

                raylib.BeginScissorMode(
                    0,
                    0,
                    raylib.GetScreenWidth(),
                    raylib.GetScreenHeight(),
                )
                defer raylib.EndScissorMode()

                rendering_command_iterator : ^microui.Command

                for rendering_command in microui.next_command_iterator(&microui_context, &rendering_command_iterator) {

                    switch command in rendering_command {



                        case ^microui.Command_Text: {

                            destination := [2]i32 {
                                command.pos.x,
                                command.pos.y,
                            }

                            for character in command.str {

                                source := microui.default_atlas[microui.DEFAULT_ATLAS_FONT + min(int(character), 127)]

                                raylib.DrawTextureRec(
                                    microui_atlas_texture,
                                    {
                                        f32(source.x),
                                        f32(source.y),
                                        f32(source.w),
                                        f32(source.h),
                                    },
                                    {
                                        f32(destination.x),
                                        f32(destination.y),
                                    },
                                    transmute(raylib.Color) command.color
                                )

                                destination.x += source.w

                            }

                        }



                        case ^microui.Command_Rect: {

                            raylib.DrawRectangle(
                                command.rect.x,
                                command.rect.y,
                                command.rect.w,
                                command.rect.h,
                                transmute(raylib.Color) command.color,
                            )

                        }



                        case ^microui.Command_Icon: {

                            source := microui.default_atlas[command.id]

                            raylib.DrawTextureRec(
                                microui_atlas_texture,
                                {
                                    f32(source.x),
                                    f32(source.y),
                                    f32(source.w),
                                    f32(source.h),
                                },
                                {
                                    f32(command.rect.x + (command.rect.w - source.w) / 2),
                                    f32(command.rect.y + (command.rect.h - source.h) / 2)
                                },
                                transmute(raylib.Color) command.color,
                            )

                        }



                        case ^microui.Command_Clip: {

                            raylib.EndScissorMode()

                            raylib.BeginScissorMode(
                                command.rect.x,
                                command.rect.y,
                                command.rect.w,
                                command.rect.h,
                            )

                        }



                        case ^microui.Command_Jump : panic("Invalid.")
                        case                       : panic("Invalid.")

                    }

                }

            }

        }

    }



    // Save the statistics.

    {

        json_file_content := json.marshal(
            v   = statistics,
            opt = {
                pretty           = true,
                use_spaces       = true,
                sort_maps_by_key = true,
                use_enum_names   = true,
            },
            allocator = context.temp_allocator,
        ) or_else panic("Failed.")

        os.write_entire_file(
            name = STATISTICS_JSON_FILE_PATH,
            data = json_file_content,
        ) or_else panic("Failed.")

    }



    // Print the statistics sorted by reaction time.

    {

        rows :  [len(statistics)]Row
        Row  :: struct {
            sign  : ASL_Sign,
            score : f64,
        }

        max_score := 0.0

        for statistic, asl_sign in statistics {

            score := score_of_statistic(statistic, false)

            max_score = max(max_score, score)

            rows[asl_sign] = {
                sign  = asl_sign,
                score = score,
            }

        }

        slice.reverse_sort_by(
            data = rows[:],
            less = proc(i, j : Row) -> bool {
                return i.score < j.score
            },
        )

        for row in rows {

            statistic := statistics[row.sign]

            fmt.printf(
                "[{}]    %6.3f seconds    %3.0f%% accuracy    %4d total attempts    -> ",
                row.sign,
                time.duration_seconds(statistic.total_duration) / f64(statistic.total_attempts),
                f32(statistic.first_try_count) / f32(statistic.total_attempts) * 100 if statistic.total_attempts != 0 else 0,
                statistic.total_attempts,
            )

            for _ in 0 ..< math.round(row.score / max_score * 100) {
                fmt.printf("#")
            }

            fmt.printf("\n")

        }

    }



}



Spline :: struct($T : typeid) {
    actual : T,
    target : T,
    lambda : f32,
}

spline_dampen :: proc(spline : ^Spline($T), delta_time : f32) {

    when T == raylib.Color {
        interpolate :: raylib.ColorLerp
    } else {
        interpolate :: linalg.lerp
    }

    spline.actual = interpolate(
        spline.target,
        spline.actual,
        math.exp(spline.lambda * delta_time),
    )

}



import "core:os"
import "core:fmt"
import "core:time"
import "core:slice"
import "core:strings"
import "core:encoding/json"
import "core:math"
import "core:math/rand"
import "core:math/linalg"
import "vendor:raylib"
import "vendor:microui"
