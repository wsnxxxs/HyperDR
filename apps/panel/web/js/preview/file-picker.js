/** Keep desktop selection independent of WebView MIME-type filters. */
export async function pickInputFile({ capabilities, dialog, fileInput, upload }) {
  const extensions = capabilities?.inputExtensions;
  if (capabilities?.nativePathInput && typeof dialog?.open === "function"
      && Array.isArray(extensions) && extensions.length) {
    const suffixes = extensions.map((value) => value.replace(/^\./, ""));
    const path = await dialog.open({
      directory: false,
      multiple: false,
      filters: [
        { name: "JPEG, PNG, HEIC/HEIF, AVIF, RAW", extensions: suffixes },
        ...suffixes.map((suffix) => ({
          name: `${suffix.toUpperCase()} (*.${suffix})`, extensions: [suffix],
        })),
      ],
    });
    if (path) await upload.startNativePath(path);
    return;
  }
  fileInput.click();
}
