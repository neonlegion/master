cmake_minimum_required(VERSION 3.16)
project(MasteringAU CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
if(NOT CMAKE_BUILD_TYPE)
    set(CMAKE_BUILD_TYPE Release)
endif()

# Portable DSP core (no Apple dependencies) — builds and tests anywhere.
add_library(mastering_dsp INTERFACE)
target_include_directories(mastering_dsp INTERFACE ${CMAKE_CURRENT_SOURCE_DIR}/Source)
if(CMAKE_CXX_COMPILER_ID MATCHES "GNU|Clang")
    target_compile_options(mastering_dsp INTERFACE -O2 -Wall -Wextra -ffp-contract=off)
endif()

add_executable(dsp_tests Tests/test_main.cpp)
target_link_libraries(dsp_tests PRIVATE mastering_dsp)

add_executable(offline_render Tools/offline_render.cpp)
target_link_libraries(offline_render PRIVATE mastering_dsp)

enable_testing()
add_test(NAME dsp_tests COMMAND dsp_tests)
