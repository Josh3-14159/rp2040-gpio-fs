cmake_minimum_required(VERSION 3.13)

set(PICO_SDK_PATH /opt/pico-sdk)

# PICO_BOARD must be set before pico_sdk_import and pico_sdk_init.
# The RP2040 Zero is a bare RP2040 with 2MB flash — the 'pico' board
# definition is the correct match. If you have a waveshare_rp2040_zero
# board file in your SDK, replace 'pico' with 'waveshare_rp2040_zero'.
set(PICO_BOARD waveshare_rp2040_zero CACHE STRING "Board type")

# SDK >= 2.0 uses picotool to produce .uf2 files. If picotool is not
# already installed on your PATH, this directive tells cmake to fetch
# and build it automatically as part of the configure step.
set(PICOTOOL_FETCH_FROM_GIT_PATH ${CMAKE_BINARY_DIR}/picotool)

include(${PICO_SDK_PATH}/external/pico_sdk_import.cmake)

project(rp2040_gpio_fs C CXX ASM)
set(CMAKE_C_STANDARD 11)
set(CMAKE_CXX_STANDARD 17)

pico_sdk_init()

set(PICO_TINYUSB_PATH ${PICO_SDK_PATH}/lib/tinyusb)

add_executable(rp2040_gpio_fs
    main.c
    usb_descriptors.c
)

message(STATUS "Building for board: ${PICO_BOARD}")
message(STATUS "TinyUSB path: ${PICO_SDK_PATH}/lib/tinyusb")

target_include_directories(rp2040_gpio_fs PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}
    ${PICO_SDK_PATH}/lib/tinyusb/src   
)

target_link_libraries(rp2040_gpio_fs
    pico_stdlib
    pico_unique_id
    hardware_gpio
    hardware_adc
    hardware_pwm
    tinyusb_device
    tinyusb_board
)

# Enable USB output, disable UART output
pico_enable_stdio_usb(rp2040_gpio_fs 0)
pico_enable_stdio_uart(rp2040_gpio_fs 0)

pico_add_extra_outputs(rp2040_gpio_fs)
