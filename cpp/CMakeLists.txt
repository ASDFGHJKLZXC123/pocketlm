cmake_minimum_required(VERSION 3.25)
project(pocketlm_core VERSION 0.1.0 LANGUAGES C CXX)

set(CMAKE_C_STANDARD 11)
set(CMAKE_C_STANDARD_REQUIRED ON)
set(CMAKE_C_EXTENSIONS OFF)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

option(POCKETLM_BUILD_TESTS "Build PocketLM tests" OFF)
option(POCKETLM_ENABLE_ASAN "Instrument PocketLM-owned targets with ASan" OFF)
option(POCKETLM_ENABLE_TSAN "Instrument PocketLM-owned targets with TSan" OFF)
option(POCKETLM_ENABLE_COVERAGE
    "Instrument PocketLM-owned targets for coverage" OFF)
option(POCKETLM_SIMULATOR_CPU_ONLY
    "Force CPU inference for iOS Simulator qualification" OFF)
option(POCKETLM_BUILD_QUALIFICATION
    "Build the host-only model qualification CLI" OFF)

if(POCKETLM_ENABLE_ASAN AND POCKETLM_ENABLE_TSAN)
    message(FATAL_ERROR "ASan and TSan must use separate build trees")
endif()
if(POCKETLM_ENABLE_TSAN AND POCKETLM_ENABLE_COVERAGE)
    message(FATAL_ERROR "TSan and coverage must use separate build trees")
endif()
if(POCKETLM_ENABLE_COVERAGE AND
   (NOT CMAKE_C_COMPILER_ID MATCHES "GNU|Clang|AppleClang" OR
    NOT CMAKE_CXX_COMPILER_ID MATCHES "GNU|Clang|AppleClang"))
    message(FATAL_ERROR
        "Coverage requires GCC or Clang-compatible C and C++ compilers "
        "(found C=${CMAKE_C_COMPILER_ID}, CXX=${CMAKE_CXX_COMPILER_ID})")
endif()

function(pocketlm_target_defaults target)
    if(CMAKE_CXX_COMPILER_ID MATCHES "GNU|Clang|AppleClang")
        target_compile_options(${target} PRIVATE
            -Wall -Wextra -Wpedantic -Wconversion -Wsign-conversion)
    endif()

    if(POCKETLM_ENABLE_ASAN)
        target_compile_options(${target} PRIVATE
            -fsanitize=address -fno-omit-frame-pointer)
        target_link_options(${target} PRIVATE -fsanitize=address)
    elseif(POCKETLM_ENABLE_TSAN)
        target_compile_options(${target} PRIVATE
            -fsanitize=thread -fno-omit-frame-pointer)
        target_link_options(${target} PRIVATE -fsanitize=thread)
    endif()

    if(POCKETLM_ENABLE_COVERAGE)
        target_compile_options(${target} PRIVATE --coverage)
        target_link_options(${target} PRIVATE --coverage)
    endif()
endfunction()

if(NOT IOS AND NOT POCKETLM_IOS_BUILD)
    set(GGML_METAL OFF CACHE BOOL "Disable Metal outside iOS builds" FORCE)
endif()
set(LLAMA_BUILD_EXAMPLES OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_TESTS OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_TOOLS OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_COMMON OFF CACHE BOOL "" FORCE)
set(LLAMA_CURL OFF CACHE BOOL "" FORCE)

add_subdirectory(third_party/llama.cpp)
find_package(Threads REQUIRED)

add_library(pocketlm_core STATIC
    src/pocketlm_core.cpp
    src/generator.cpp
    src/llama_backend.cpp
    src/tokenizer.cpp
    src/metrics.cpp
)
target_include_directories(pocketlm_core
    PUBLIC ${CMAKE_CURRENT_SOURCE_DIR}/include
    PRIVATE
        ${CMAKE_CURRENT_SOURCE_DIR}/src
        ${CMAKE_CURRENT_SOURCE_DIR}/third_party/llama.cpp/include
)
target_link_libraries(pocketlm_core PUBLIC llama PRIVATE Threads::Threads)
target_compile_features(pocketlm_core PRIVATE cxx_std_17)
if(POCKETLM_SIMULATOR_CPU_ONLY)
    target_compile_definitions(pocketlm_core PRIVATE
        POCKETLM_SIMULATOR_CPU_ONLY=1)
endif()
pocketlm_target_defaults(pocketlm_core)

add_executable(pocketlm_smoke src/smoke_main.cpp)
target_link_libraries(pocketlm_smoke PRIVATE pocketlm_core Threads::Threads)
pocketlm_target_defaults(pocketlm_smoke)

# Host-side qualification tool. Keep it out of iOS app builds. The calling
# script atomically captures its stdout JSON/JSONL.
if(POCKETLM_BUILD_QUALIFICATION AND NOT IOS AND NOT POCKETLM_IOS_BUILD)
    add_executable(pocketlm_qualify tools/pocketlm_qualify.cpp)
    target_link_libraries(pocketlm_qualify PRIVATE pocketlm_core Threads::Threads)
    pocketlm_target_defaults(pocketlm_qualify)
endif()

install(TARGETS pocketlm_core ARCHIVE DESTINATION lib)
install(FILES include/pocketlm_core.h DESTINATION include)

if(POCKETLM_BUILD_TESTS)
    include(CTest)
    enable_testing()

    include(FetchContent)
    FetchContent_Declare(
        Catch2
        GIT_REPOSITORY https://github.com/catchorg/Catch2.git
        GIT_TAG 8ac8190e494a381072c89f5e161b92a08d98b37b
    )
    FetchContent_MakeAvailable(Catch2)
    include(Catch)

    function(pocketlm_add_catch_test target)
        add_executable(${target} ${ARGN})
        target_include_directories(${target} PRIVATE
            ${CMAKE_CURRENT_SOURCE_DIR}/include
            ${CMAKE_CURRENT_SOURCE_DIR}/src
            ${CMAKE_CURRENT_SOURCE_DIR}/tests
        )
        target_link_libraries(${target} PRIVATE
            pocketlm_core Catch2::Catch2WithMain Threads::Threads)
        target_compile_features(${target} PRIVATE cxx_std_17)
        pocketlm_target_defaults(${target})
        if(target STREQUAL "test_async")
            catch_discover_tests(${target} PROPERTIES
                LABELS m1a
                TEST_LIST pocketlm_concurrency_tests)
        else()
            catch_discover_tests(${target} PROPERTIES LABELS m1a)
        endif()
    endfunction()

    pocketlm_add_catch_test(test_api tests/test_api.cpp)
    pocketlm_add_catch_test(test_utf8 tests/test_utf8.cpp)
    pocketlm_add_catch_test(test_tokenizer tests/test_tokenizer.cpp)
    pocketlm_add_catch_test(test_async
        tests/test_async_contract.cpp
        tests/test_lifecycle.cpp
        tests/test_context.cpp
        tests/fakes/fake_backend.cpp
    )
    file(GENERATE
        OUTPUT "${CMAKE_CURRENT_BINARY_DIR}/pocketlm_concurrency_labels.cmake"
        CONTENT [=[
if(DEFINED pocketlm_concurrency_tests)
    set_tests_properties(${pocketlm_concurrency_tests} PROPERTIES
        LABELS "m1a;concurrency")
endif()
]=])
    set_property(DIRECTORY APPEND PROPERTY TEST_INCLUDE_FILES
        "${CMAKE_CURRENT_BINARY_DIR}/pocketlm_concurrency_labels.cmake")

    add_executable(test_model_backend tests/test_model_backend.cpp)
    target_include_directories(test_model_backend PRIVATE
        ${CMAKE_CURRENT_SOURCE_DIR}/include
        ${CMAKE_CURRENT_SOURCE_DIR}/src
        ${CMAKE_CURRENT_SOURCE_DIR}/tests
        ${CMAKE_CURRENT_SOURCE_DIR}/third_party/llama.cpp/include
    )
    target_link_libraries(test_model_backend PRIVATE
        pocketlm_core Catch2::Catch2WithMain Threads::Threads)
    target_compile_features(test_model_backend PRIVATE cxx_std_17)
    pocketlm_target_defaults(test_model_backend)
    catch_discover_tests(test_model_backend PROPERTIES
        LABELS m2-model
        SKIP_RETURN_CODE 4
    )

    add_executable(test_header_c tests/header_compile.c)
    target_include_directories(test_header_c PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}/include)
    target_link_libraries(test_header_c PRIVATE pocketlm_core)
    set_property(TARGET test_header_c PROPERTY LINKER_LANGUAGE CXX)
    pocketlm_target_defaults(test_header_c)
    add_test(NAME header_compile_c COMMAND test_header_c)
    set_tests_properties(header_compile_c PROPERTIES LABELS m1a)

    add_executable(test_header_cpp tests/header_compile.cpp)
    target_include_directories(test_header_cpp PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}/include)
    target_link_libraries(test_header_cpp PRIVATE pocketlm_core)
    pocketlm_target_defaults(test_header_cpp)
    add_test(NAME header_compile_cpp COMMAND test_header_cpp)
    set_tests_properties(header_compile_cpp PROPERTIES LABELS m1a)
endif()
