cmake_minimum_required(VERSION 3.20)
project(hpmmo_service CXX C)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

if(NOT CMAKE_BUILD_TYPE)
    set(CMAKE_BUILD_TYPE Release)
endif()

# --- vendored headers (see vendor/PROVENANCE.md) ---
add_library(vendor_headers INTERFACE)
target_include_directories(vendor_headers INTERFACE
    ${CMAKE_CURRENT_SOURCE_DIR}/vendor
    ${CMAKE_CURRENT_SOURCE_DIR}/vendor/httplib
    ${CMAKE_CURRENT_SOURCE_DIR}/vendor/nlohmann)

# --- argon2 (vendored source build) ---
add_library(argon2 STATIC
    vendor/argon2/argon2.c
    vendor/argon2/core.c
    vendor/argon2/blake2/blake2b.c
    vendor/argon2/encoding.c
    vendor/argon2/ref.c
    vendor/argon2/thread.c)
target_include_directories(argon2 PUBLIC ${CMAKE_CURRENT_SOURCE_DIR}/vendor/argon2)
if(NOT WIN32)
    target_link_libraries(argon2 PUBLIC pthread)
endif()

# --- libpq ---
if(NOT PG_ROOT)
    if(DEFINED ENV{HPMMO_PG_ROOT})
        set(PG_ROOT "$ENV{HPMMO_PG_ROOT}")
    else()
        set(PG_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/../../../_tools/pgsql")
    endif()
endif()
message(STATUS "PG_ROOT = ${PG_ROOT}")
find_path(PG_INCLUDE_DIR libpq-fe.h
    PATHS ${PG_ROOT}/include /usr/include/postgresql /usr/local/include/postgresql
    PATH_SUFFIXES postgresql)
if(NOT PG_INCLUDE_DIR)
    find_path(PG_INCLUDE_DIR libpq-fe.h)
endif()
find_library(PG_LIBRARY NAMES pq libpq libpq.a
    PATHS ${PG_ROOT}/lib /usr/lib /usr/local/lib /usr/lib/x86_64-linux-gnu /usr/lib/aarch64-linux-gnu)
if(NOT PG_LIBRARY)
    find_library(PG_LIBRARY NAMES pq libpq)
endif()
if(NOT PG_INCLUDE_DIR OR NOT PG_LIBRARY)
    message(FATAL_ERROR "libpq not found - set -DPG_ROOT=<postgres binaries root> or HPMMO_PG_ROOT")
endif()
message(STATUS "Found libpq include: ${PG_INCLUDE_DIR}")
message(STATUS "Found libpq library: ${PG_LIBRARY}")

add_executable(hpmmo_service
    src/main.cpp
    src/db.cpp
    src/auth.cpp
    src/app.cpp)
target_include_directories(hpmmo_service PRIVATE src ${PG_INCLUDE_DIR})
target_link_libraries(hpmmo_service PRIVATE vendor_headers argon2 ${PG_LIBRARY})
if(WIN32)
    target_link_libraries(hpmmo_service PRIVATE ws2_32 bcrypt)
endif()

# Ship the libpq runtime chain next to the exe so the service runs without
# PATH edits (minimal load-time set verified on Windows 11 + PG 17):
# libpq -> libintl/libiconv; ssl/crypto are loaded lazily for SSL sessions.
if(WIN32)
    foreach(dll libpq.dll libintl-9.dll libiconv-2.dll libssl-3-x64.dll libcrypto-3-x64.dll)
        if(EXISTS "${PG_ROOT}/bin/${dll}")
            add_custom_command(TARGET hpmmo_service POST_BUILD
                COMMAND ${CMAKE_COMMAND} -E copy_if_different
                    "${PG_ROOT}/bin/${dll}" "$<TARGET_FILE_DIR:hpmmo_service>")
        endif()
    endforeach()
endif()
