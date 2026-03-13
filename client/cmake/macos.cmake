message("MAC build")

find_library(FW_SYSTEMCONFIG SystemConfiguration)
find_library(FW_SERVICEMGMT ServiceManagement)
find_library(FW_SECURITY Security)
find_library(FW_COREWLAN CoreWLAN)
find_library(FW_NETWORK Network)
find_library(FW_USER_NOTIFICATIONS UserNotifications)
find_library(FW_NETWORK_EXTENSION NetworkExtension)

set(LIBS ${LIBS}
    ${FW_SYSTEMCONFIG}
    ${FW_SERVICEMGMT}
    ${FW_SECURITY}
    ${FW_COREWLAN}
    ${FW_NETWORK}
    ${FW_USER_NOTIFICATIONS}
    ${FW_NETWORK_EXTENSION}
)

set_target_properties(${PROJECT} PROPERTIES 
    MACOSX_BUNDLE TRUE
    MACOSX_BUNDLE_SHORT_VERSION_STRING "${CMAKE_PROJECT_VERSION_MAJOR}.${CMAKE_PROJECT_VERSION_MINOR}.${CMAKE_PROJECT_VERSION_PATCH}"
    MACOSX_BUNDLE_BUNDLE_VERSION "${CMAKE_PROJECT_VERSION_TWEAK}"
)
# Build a universal binary so the app runs natively on both Intel (x86_64) and
# Apple Silicon (arm64) Macs. Rosetta 2 emulation is no longer needed on M1+.
# NOTE: the bundled wireguard-go executable and any other prebuilt binaries must
# also be universal (arm64;x86_64) for this to have full effect.
set(CMAKE_OSX_ARCHITECTURES "arm64;x86_64" CACHE INTERNAL "" FORCE)
set(CMAKE_OSX_DEPLOYMENT_TARGET 11.0)


set(HEADERS ${HEADERS}
    ${CMAKE_CURRENT_SOURCE_DIR}/ui/macos_util.h
)

set(SOURCES ${SOURCES}
    ${CMAKE_CURRENT_SOURCE_DIR}/ui/macos_util.mm
)



set(ICON_FILE ${CMAKE_CURRENT_SOURCE_DIR}/images/app.icns)
set(MACOSX_BUNDLE_ICON_FILE app.icns)
set_source_files_properties(${ICON_FILE} PROPERTIES MACOSX_PACKAGE_LOCATION Resources)
set(SOURCES ${SOURCES} ${ICON_FILE})

target_compile_options(${PROJECT} PRIVATE
    -DGROUP_ID=\"${BUILD_IOS_GROUP_IDENTIFIER}\"
    -DVPN_NE_BUNDLEID=\"${BUILD_IOS_APP_IDENTIFIER}.network-extension\"
)

# Get SDK path
execute_process(
    COMMAND sh -c "xcrun --sdk macosx --show-sdk-path"
    OUTPUT_VARIABLE OSX_SDK_PATH
    OUTPUT_STRIP_TRAILING_WHITESPACE
)
message("OSX_SDK_PATH is: ${OSX_SDK_PATH}")

# ---------------------------------------------------------------------------
# wireguard-go universal binary
#
# The daemon launches wireguard-go (an AmneziaWG-fork process) at runtime.
# We build a universal (arm64 + x86_64) binary via a custom target so that
# `cmake --build` always has a fresh binary ready before the app is packaged.
#
# The Go toolchain is optional at CMake-configure time; the target simply
# warns when 'go' is absent.  In that case the build_wireguard_go_macos.sh
# script (called from build_macos.sh or CI) must be run separately.
#
# The output is written to the same deploy-prebuilt directory that
# build_macos.sh reads when copying binaries into the app bundle.
# ---------------------------------------------------------------------------
set(WIREGUARD_GO_BUILD_SCRIPT
    "${CMAKE_SOURCE_DIR}/deploy/build_wireguard_go_macos.sh")
set(WIREGUARD_GO_OUTPUT_DIR
    "${CMAKE_SOURCE_DIR}/deploy/data/deploy-prebuilt/macos")
set(WIREGUARD_GO_OUTPUT
    "${WIREGUARD_GO_OUTPUT_DIR}/wireguard-go")

find_program(GO_EXECUTABLE go)

if(GO_EXECUTABLE)
    message(STATUS "Go toolchain found: ${GO_EXECUTABLE} — wireguard-go will be built as part of the build")

    add_custom_command(
        OUTPUT "${WIREGUARD_GO_OUTPUT}"
        COMMAND ${CMAKE_COMMAND} -E make_directory "${WIREGUARD_GO_OUTPUT_DIR}"
        COMMAND bash "${WIREGUARD_GO_BUILD_SCRIPT}" "${WIREGUARD_GO_OUTPUT_DIR}"
        COMMENT "Building universal wireguard-go (arm64 + x86_64)"
        VERBATIM
    )

    add_custom_target(wireguard_go_universal ALL
        DEPENDS "${WIREGUARD_GO_OUTPUT}"
    )

    # Ensure the main app target is built after wireguard-go is ready
    add_dependencies(${PROJECT} wireguard_go_universal)

    # Copy the universal binary into the app bundle after the app is built
    add_custom_command(TARGET ${PROJECT} POST_BUILD
        COMMAND ${CMAKE_COMMAND} -E copy_if_different
            "${WIREGUARD_GO_OUTPUT}"
            "$<TARGET_BUNDLE_DIR:${PROJECT}>/Contents/MacOS/wireguard-go"
        COMMENT "Installing universal wireguard-go into app bundle"
    )
else()
    message(WARNING
        "Go toolchain not found — wireguard-go will NOT be built automatically.\n"
        "Run 'bash deploy/build_wireguard_go_macos.sh' before packaging, or\n"
        "set SKIP_WIREGUARD_GO_BUILD=1 and provide a pre-built universal binary.")
endif()

