cmake_minimum_required(VERSION 3.20)
project(DonbyKernel LANGUAGES C CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_C_STANDARD 11)

include_directories(
    ${CMAKE_CURRENT_SOURCE_DIR}/Sources/DonbyKernelC/include
    ${CMAKE_CURRENT_SOURCE_DIR}/KernelRust/include
    /opt/homebrew/include
    /opt/homebrew/opt/ffmpeg/include
    /opt/homebrew/opt/libass/include
)

link_directories(
    /opt/homebrew/lib
    /opt/homebrew/opt/ffmpeg/lib
    /opt/homebrew/opt/libass/lib
    ${CMAKE_CURRENT_SOURCE_DIR}/KernelRust/target/release
)

add_library(donby_kernel STATIC
    Sources/DonbyKernelC/dk_engine.cpp
)

target_link_libraries(donby_kernel
    donby_rs
    avformat
    avcodec
    avutil
    swresample
    swscale
    ass
    "-framework CoreVideo"
    "-framework VideoToolbox"
    "-framework AudioToolbox"
    "-framework CoreFoundation"
)
