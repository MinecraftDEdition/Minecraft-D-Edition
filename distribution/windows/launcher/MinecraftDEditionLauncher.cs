// Windows-only launcher and differential updater.
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Net;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Security.Cryptography;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using System.Windows.Forms;

[assembly: System.Reflection.AssemblyTitle("Minecraft: D Edition Launcher")]
[assembly: System.Reflection.AssemblyProduct("Minecraft: D Edition")]
[assembly: System.Reflection.AssemblyCompany("Minecraft: D Edition")]
[assembly: System.Reflection.AssemblyVersion("1.0.0.0")]

namespace MinecraftDEdition.Updater
{
    internal sealed class ChunkRecord
    {
        internal string Name;
        internal long Size;
        internal string Sha256;
    }

    internal sealed class FileRecord
    {
        internal string Path;
        internal long Size;
        internal string Sha256;
        internal string Chunk;
    }

    internal sealed class UpdateManifest
    {
        internal string Version;
        internal string RawText;
        internal readonly Dictionary<string, ChunkRecord> Chunks =
            new Dictionary<string, ChunkRecord>(StringComparer.OrdinalIgnoreCase);
        internal readonly Dictionary<string, FileRecord> Files =
            new Dictionary<string, FileRecord>(StringComparer.OrdinalIgnoreCase);

        internal static UpdateManifest Parse(string text)
        {
            string normalized = text.Replace("\r\n", "\n");
            string[] lines = normalized.Split('\n');
            if (lines.Length == 0 || lines[0] != "MDE-UPDATE-MANIFEST\t1")
                throw new InvalidDataException("Unsupported update manifest format.");

            UpdateManifest result = new UpdateManifest();
            result.RawText = normalized.EndsWith("\n", StringComparison.Ordinal)
                ? normalized : normalized + "\n";
            foreach (string line in lines.Skip(1))
            {
                if (String.IsNullOrWhiteSpace(line) || line[0] == '#')
                    continue;
                string[] fields = line.Split('\t');
                if (fields[0] == "version" && fields.Length == 2)
                {
                    result.Version = fields[1];
                }
                else if (fields[0] == "chunk" && fields.Length == 4)
                {
                    ChunkRecord chunk = new ChunkRecord();
                    chunk.Name = fields[1];
                    chunk.Size = Int64.Parse(fields[2]);
                    chunk.Sha256 = ValidateHash(fields[3]);
                    result.Chunks.Add(chunk.Name, chunk);
                }
                else if (fields[0] == "file" && fields.Length == 5)
                {
                    FileRecord file = new FileRecord();
                    file.Path = ValidateRelativePath(fields[1]);
                    file.Size = Int64.Parse(fields[2]);
                    file.Sha256 = ValidateHash(fields[3]);
                    file.Chunk = fields[4];
                    result.Files.Add(file.Path, file);
                }
                else
                {
                    throw new InvalidDataException("Malformed update manifest line.");
                }
            }
            if (String.IsNullOrWhiteSpace(result.Version))
                throw new InvalidDataException("Update manifest has no version.");
            foreach (FileRecord file in result.Files.Values)
                if (!result.Chunks.ContainsKey(file.Chunk))
                    throw new InvalidDataException("A file references an unknown update shard.");
            return result;
        }

        private static string ValidateHash(string value)
        {
            if (value.Length != 64 || value.Any(delegate(char c) {
                return !Uri.IsHexDigit(c);
            }))
                throw new InvalidDataException("Invalid SHA-256 value in manifest.");
            return value.ToLowerInvariant();
        }

        internal static string ValidateRelativePath(string value)
        {
            string path = value.Replace('\\', '/');
            if (String.IsNullOrWhiteSpace(path) || path.StartsWith("/", StringComparison.Ordinal)
                || path.Contains(":") || path.Contains("\t") || path.Contains("\n"))
                throw new InvalidDataException("Unsafe path in update manifest.");
            foreach (string part in path.Split('/'))
                if (part.Length == 0 || part == "." || part == "..")
                    throw new InvalidDataException("Unsafe path in update manifest.");
            return path;
        }
    }

    internal sealed class UpdatePointer
    {
        internal string Version;
        internal string Manifest;
        internal long Size;
        internal string Sha256;

        internal static UpdatePointer Parse(string text)
        {
            string[] lines = text.Replace("\r\n", "\n").Split('\n');
            if (lines.Length == 0 || lines[0] != "MDE-UPDATE-POINTER\t1")
                throw new InvalidDataException("Unsupported update pointer format.");
            UpdatePointer result = new UpdatePointer();
            foreach (string line in lines.Skip(1))
            {
                if (String.IsNullOrWhiteSpace(line))
                    continue;
                string[] fields = line.Split('\t');
                if (fields.Length != 2)
                    throw new InvalidDataException("Malformed update pointer.");
                if (fields[0] == "version") result.Version = fields[1];
                else if (fields[0] == "manifest")
                    result.Manifest = UpdateManifest.ValidateRelativePath(fields[1]);
                else if (fields[0] == "size") result.Size = Int64.Parse(fields[1]);
                else if (fields[0] == "sha256") result.Sha256 = fields[1].ToLowerInvariant();
                else throw new InvalidDataException("Unknown update pointer field.");
            }
            if (String.IsNullOrWhiteSpace(result.Version)
                || String.IsNullOrWhiteSpace(result.Manifest) || result.Size <= 0
                || String.IsNullOrWhiteSpace(result.Sha256) || result.Sha256.Length != 64
                || result.Sha256.Any(delegate(char c) { return !Uri.IsHexDigit(c); }))
                throw new InvalidDataException("Incomplete update pointer.");
            return result;
        }
    }

    internal sealed class LauncherForm : Form
    {
        private const string Repository = "MinecraftDEdition/Minecraft-D-Edition";
        private const string ChannelTag = "Test";
        private const string ManifestAsset = "mde-update-manifest-v1.txt";
        private const string PointerAsset = "mde-update-pointer-v1.txt";
        private const string GameExecutable = "Minecraft D Edition.exe";
        private const string LauncherExecutable = "Minecraft D Edition Launcher.exe";
        private const string LauncherUpdateExecutable =
            "Minecraft D Edition Launcher.update.exe";
        private const string InstalledManifest = ".mde-installed-manifest.txt";

        private readonly string[] gameArguments;
        private readonly bool checkOnly;
        private readonly Label heading;
        private readonly Label status;
        private readonly Label details;
        private readonly ProgressBar progress;
        private static readonly HttpClient Http = CreateHttpClient();

        internal LauncherForm(string[] arguments)
        {
            List<string> forwarded = new List<string>();
            foreach (string argument in arguments)
            {
                if (String.Equals(argument, "--updater-check-only",
                    StringComparison.OrdinalIgnoreCase))
                    checkOnly = true;
                else
                    forwarded.Add(argument);
            }
            gameArguments = forwarded.ToArray();

            Text = "Minecraft: D Edition Installer";
            ClientSize = new Size(560, 218);
            FormBorderStyle = FormBorderStyle.FixedDialog;
            MaximizeBox = false;
            MinimizeBox = false;
            ControlBox = false;
            StartPosition = FormStartPosition.CenterScreen;
            BackColor = Color.FromArgb(30, 30, 30);
            ForeColor = Color.White;
            try { Icon = Icon.ExtractAssociatedIcon(Application.ExecutablePath); }
            catch { }

            PictureBox logo = new PictureBox();
            logo.Location = new Point(22, 22);
            logo.Size = new Size(56, 56);
            logo.SizeMode = PictureBoxSizeMode.Zoom;
            if (Icon != null) logo.Image = Icon.ToBitmap();
            Controls.Add(logo);

            heading = new Label();
            heading.AutoSize = false;
            heading.Location = new Point(94, 20);
            heading.Size = new Size(440, 34);
            heading.Font = new Font("Segoe UI", 17.0f, FontStyle.Bold);
            heading.Text = "Minecraft: D Edition";
            Controls.Add(heading);

            Label subtitle = new Label();
            subtitle.AutoSize = false;
            subtitle.Location = new Point(96, 55);
            subtitle.Size = new Size(438, 24);
            subtitle.ForeColor = Color.FromArgb(190, 190, 190);
            subtitle.Font = new Font("Segoe UI", 9.0f);
            subtitle.Text = "Secure installation and updates delivered through GitHub";
            Controls.Add(subtitle);

            status = new Label();
            status.AutoSize = false;
            status.Location = new Point(22, 101);
            status.Size = new Size(516, 28);
            status.Font = new Font("Segoe UI", 10.0f, FontStyle.Bold);
            status.Text = "Checking for updates...";
            status.TextAlign = ContentAlignment.MiddleLeft;
            Controls.Add(status);

            details = new Label();
            details.AutoSize = false;
            details.Location = new Point(22, 132);
            details.Size = new Size(516, 24);
            details.ForeColor = Color.FromArgb(180, 180, 180);
            details.Font = new Font("Segoe UI", 8.5f);
            details.Text = "Contacting github.com";
            Controls.Add(details);

            progress = new ProgressBar();
            progress.Location = new Point(22, 169);
            progress.Size = new Size(516, 24);
            progress.Style = ProgressBarStyle.Marquee;
            Controls.Add(progress);
        }

        protected override async void OnShown(EventArgs e)
        {
            base.OnShown(e);
            try
            {
                bool launchHere = await Task.Run(delegate {
                    return CheckAndApplyUpdates();
                });
                if (launchHere && !checkOnly)
                    LaunchGame();
                Close();
            }
            catch (Exception exception)
            {
                progress.Style = ProgressBarStyle.Blocks;
                SetStatus("The update could not be completed.");
                SetDetails("Your existing game files were left unchanged.");
                MessageBox.Show(this,
                    "Minecraft: D Edition was not changed.\n\n" + exception.Message,
                    "Update failed", MessageBoxButtons.OK, MessageBoxIcon.Error);
                Environment.ExitCode = 1;
                Close();
            }
        }

        private static HttpClient CreateHttpClient()
        {
            ServicePointManager.SecurityProtocol = SecurityProtocolType.Tls12;
            HttpClient client = new HttpClient();
            client.Timeout = TimeSpan.FromMinutes(20);
            client.DefaultRequestHeaders.UserAgent.ParseAdd(
                "Minecraft-D-Edition-Updater/1.0");
            client.DefaultRequestHeaders.CacheControl =
                new CacheControlHeaderValue { NoCache = true, NoStore = true };
            return client;
        }

        private bool CheckAndApplyUpdates()
        {
            string root = AppDomain.CurrentDomain.BaseDirectory;
            bool gameInstalled = File.Exists(Path.Combine(root, GameExecutable));
            string overrideUrl = Environment.GetEnvironmentVariable("MDE_UPDATE_MANIFEST_URL");
            string installedPath = Path.Combine(root, InstalledManifest);
            UpdateManifest installed = TryReadManifest(installedPath);
            string manifestUrl;
            UpdatePointer pointer = null;
            if (!String.IsNullOrWhiteSpace(overrideUrl))
            {
                manifestUrl = overrideUrl;
            }
            else
            {
                string pointerText = TryDownloadText(ReleaseAssetUrl(PointerAsset));
                if (pointerText == null)
                {
                    if (!gameInstalled)
                        throw new InvalidOperationException(
                            "The GitHub installation feed has not been published yet.");
                    SetStatus("No update feed has been published yet.");
                    SetDetails("Starting the installed game without updating.");
                    return true;
                }
                pointer = UpdatePointer.Parse(pointerText);
                manifestUrl = ReleaseAssetUrl(pointer.Manifest);
            }

            byte[] remoteBytes = null;
            // A verified installed copy of the current manifest avoids a
            // redundant multi-megabyte download, but never skips checking the
            // files themselves. Deleted or corrupted files are repaired even
            // when the version number has not changed.
            if (pointer != null && installed != null
                && String.Equals(installed.Version, pointer.Version,
                    StringComparison.Ordinal))
            {
                byte[] installedBytes = Encoding.UTF8.GetBytes(installed.RawText);
                if (installedBytes.LongLength == pointer.Size
                    && HashBytes(installedBytes).Equals(pointer.Sha256,
                        StringComparison.OrdinalIgnoreCase))
                    remoteBytes = installedBytes;
            }
            try
            {
                if (remoteBytes == null)
                using (HttpResponseMessage response = GetWithRetries(
                    CacheBust(manifestUrl), HttpCompletionOption.ResponseContentRead))
                {
                    if (response.StatusCode == HttpStatusCode.NotFound)
                    {
                        SetStatus("No update feed has been published yet.");
                        if (!gameInstalled)
                            throw new InvalidOperationException(
                                "The GitHub installation manifest is unavailable.");
                        return true;
                    }
                    response.EnsureSuccessStatusCode();
                    remoteBytes = response.Content.ReadAsByteArrayAsync().Result;
                }
            }
            catch (Exception exception)
            {
                if (IsNetworkFailure(exception))
                {
                    if (!gameInstalled)
                        throw new InvalidOperationException(
                            "An internet connection is required for the first installation.",
                            exception);
                    SetStatus("Offline - starting the installed game.");
                    SetDetails("Updates will be checked the next time you launch.");
                    return true;
                }
                throw;
            }

            if (pointer != null && (remoteBytes.LongLength != pointer.Size
                || !HashBytes(remoteBytes).Equals(pointer.Sha256,
                    StringComparison.OrdinalIgnoreCase)))
                throw new InvalidDataException("The update manifest failed verification.");
            string remoteText = Encoding.UTF8.GetString(remoteBytes);
            UpdateManifest remote = UpdateManifest.Parse(remoteText);
            if (pointer != null && !String.Equals(pointer.Version, remote.Version,
                StringComparison.Ordinal))
                throw new InvalidDataException("The update pointer and manifest disagree.");
            List<FileRecord> changed = FindChangedFiles(root, remote);
            List<string> removed = FindRemovedFiles(installed, remote);
            if (changed.Count == 0 && removed.Count == 0)
            {
                WriteInstalledManifest(root, remote.RawText);
                SetStatus("Minecraft: D Edition is up to date.");
                SetDetails("All installed files match version " + remote.Version + ".");
                return true;
            }

            bool firstInstall = installed == null || !gameInstalled;
            SetStatus((firstInstall ? "Installing " : "Updating to ")
                + remote.Version + "...");
            string workRoot = Path.Combine(root, ".mde-update");
            Directory.CreateDirectory(workRoot);
            CleanupOldUpdateSessions(workRoot);
            string work = Path.Combine(workRoot, "session-"
                + Guid.NewGuid().ToString("N"));
            string stage = Path.Combine(work, "stage");
            string downloads = Path.Combine(work, "downloads");
            Directory.CreateDirectory(stage);
            Directory.CreateDirectory(downloads);

            Dictionary<string, List<FileRecord>> byChunk = changed.GroupBy(
                delegate(FileRecord file) { return file.Chunk; },
                StringComparer.OrdinalIgnoreCase).ToDictionary(
                    delegate(IGrouping<string, FileRecord> group) { return group.Key; },
                    delegate(IGrouping<string, FileRecord> group) { return group.ToList(); },
                    StringComparer.OrdinalIgnoreCase);

            int completedChunks = 0;
            long totalBytes = byChunk.Keys.Sum(delegate(string name) {
                return remote.Chunks[name].Size;
            });
            long completedBytes = 0;
            SetProgress(0, "Preparing " + changed.Count + " files...");
            foreach (KeyValuePair<string, List<FileRecord>> group in byChunk)
            {
                ChunkRecord chunk = remote.Chunks[group.Key];
                SetStatus((firstInstall ? "Downloading game files "
                    : "Downloading update files ") + (completedChunks + 1)
                    + " of " + byChunk.Count + "...");
                string archive = Path.Combine(downloads, chunk.Name);
                DownloadChunk(chunk, archive, completedBytes, totalBytes);
                ExtractChangedFiles(archive, stage, group.Value);
                completedBytes += chunk.Size;
                ++completedChunks;
            }

            SetStatus("Installing update...");
            SetProgress(100, "Verifying and applying files...");
            if (changed.Any(delegate(FileRecord file) {
                return String.Equals(file.Path, LauncherExecutable,
                        StringComparison.OrdinalIgnoreCase)
                    || String.Equals(file.Path, LauncherUpdateExecutable,
                        StringComparison.OrdinalIgnoreCase);
            }))
            {
                StartDeferredUpdate(root, work, stage, remote, changed, removed);
                SetStatus("Finishing launcher update...");
                SetDetails("Minecraft: D Edition will start automatically.");
                return false;
            }
            ApplyWithRollback(root, work, stage, changed, removed);
            WriteInstalledManifest(root, remote.RawText);
            TryDeleteDirectory(work);
            SetStatus("Update complete.");
            SetDetails("Starting Minecraft: D Edition...");
            return true;
        }

        private static List<FileRecord> FindChangedFiles(string root,
            UpdateManifest remote)
        {
            List<FileRecord> changed = new List<FileRecord>();
            foreach (FileRecord file in remote.Files.Values)
            {
                string destination = LocalPath(root, file.Path);
                if (File.Exists(destination) && new FileInfo(destination).Length == file.Size
                    && HashFile(destination).Equals(file.Sha256,
                        StringComparison.OrdinalIgnoreCase))
                    continue;
                changed.Add(file);
            }
            return changed;
        }

        private static List<string> FindRemovedFiles(UpdateManifest installed,
            UpdateManifest remote)
        {
            if (installed == null)
                return new List<string>();
            return installed.Files.Keys.Where(delegate(string path) {
                return !remote.Files.ContainsKey(path);
            }).ToList();
        }

        private static void ExtractChangedFiles(string archive, string stage,
            List<FileRecord> wanted)
        {
            Dictionary<string, FileRecord> remaining = wanted.ToDictionary(
                delegate(FileRecord file) { return file.Path; },
                StringComparer.OrdinalIgnoreCase);
            using (FileStream stream = File.OpenRead(archive))
            using (ZipArchive zip = new ZipArchive(stream, ZipArchiveMode.Read))
            {
                foreach (ZipArchiveEntry entry in zip.Entries)
                {
                    string path = UpdateManifest.ValidateRelativePath(entry.FullName);
                    FileRecord expected;
                    if (!remaining.TryGetValue(path, out expected))
                        continue;
                    string destination = LocalPath(stage, path);
                    Directory.CreateDirectory(Path.GetDirectoryName(destination));
                    using (Stream source = entry.Open())
                    using (FileStream output = File.Create(destination))
                        source.CopyTo(output);
                    FileInfo info = new FileInfo(destination);
                    if (info.Length != expected.Size
                        || !HashFile(destination).Equals(expected.Sha256,
                            StringComparison.OrdinalIgnoreCase))
                        throw new InvalidDataException("An updated file failed verification: "
                            + path);
                    remaining.Remove(path);
                }
            }
            if (remaining.Count != 0)
                throw new InvalidDataException("An update shard did not contain every required file.");
        }

        internal static void ApplyWithRollback(string root, string work, string stage,
            List<FileRecord> changed, List<string> removed)
        {
            string backup = Path.Combine(work, "backup");
            Directory.CreateDirectory(backup);
            List<string> newFiles = new List<string>();
            try
            {
                // Validate the complete staged set before touching a live file.
                foreach (FileRecord file in changed)
                {
                    string staged = LocalPath(stage, file.Path);
                    if (!File.Exists(staged) || new FileInfo(staged).Length != file.Size
                        || !HashFile(staged).Equals(file.Sha256,
                            StringComparison.OrdinalIgnoreCase))
                        throw new InvalidDataException(
                            "A staged update file failed preflight verification: "
                            + file.Path);
                }
                foreach (string path in removed.Concat(changed.Select(
                    delegate(FileRecord file) { return file.Path; })).Distinct(
                        StringComparer.OrdinalIgnoreCase))
                {
                    string destination = LocalPath(root, path);
                    if (File.Exists(destination))
                    {
                        string backupPath = LocalPath(backup, path);
                        Directory.CreateDirectory(Path.GetDirectoryName(backupPath));
                        File.Copy(destination, backupPath, true);
                    }
                    else
                        newFiles.Add(path);
                }

                foreach (FileRecord file in changed)
                {
                    string source = LocalPath(stage, file.Path);
                    string destination = LocalPath(root, file.Path);
                    Directory.CreateDirectory(Path.GetDirectoryName(destination));
                    ReplaceAtomically(source, destination);
                }
                foreach (string path in removed)
                {
                    string destination = LocalPath(root, path);
                    if (File.Exists(destination))
                        File.Delete(destination);
                }
            }
            catch
            {
                foreach (string path in newFiles)
                {
                    string destination = LocalPath(root, path);
                    if (File.Exists(destination))
                        File.Delete(destination);
                }
                if (Directory.Exists(backup))
                {
                    foreach (string backupFile in Directory.GetFiles(backup, "*",
                        SearchOption.AllDirectories))
                    {
                        string relative = backupFile.Substring(backup.Length + 1);
                        string destination = LocalPath(root, relative);
                        Directory.CreateDirectory(Path.GetDirectoryName(destination));
                        ReplaceAtomically(backupFile, destination);
                    }
                }
                throw;
            }
        }

        internal static UpdateManifest TryReadManifest(string path)
        {
            try
            {
                return File.Exists(path) ? UpdateManifest.Parse(
                    File.ReadAllText(path, Encoding.UTF8)) : null;
            }
            catch
            {
                return null;
            }
        }

        internal static void WriteInstalledManifest(string root, string text)
        {
            string destination = Path.Combine(root, InstalledManifest);
            string temporary = destination + ".new";
            File.WriteAllText(temporary, text, new UTF8Encoding(false));
            if (File.Exists(destination))
                File.Replace(temporary, destination, null);
            else
                File.Move(temporary, destination);
        }

        internal static string HashFile(string path)
        {
            using (SHA256 sha = SHA256.Create())
            using (FileStream stream = new FileStream(path, FileMode.Open,
                FileAccess.Read, FileShare.Read))
                return BitConverter.ToString(sha.ComputeHash(stream)).Replace("-", "")
                    .ToLowerInvariant();
        }

        private static string HashBytes(byte[] bytes)
        {
            using (SHA256 sha = SHA256.Create())
                return BitConverter.ToString(sha.ComputeHash(bytes)).Replace("-", "")
                    .ToLowerInvariant();
        }

        private static string TryDownloadText(string url)
        {
            try
            {
                using (HttpResponseMessage response = GetWithRetries(
                    CacheBust(url), HttpCompletionOption.ResponseContentRead))
                {
                    if (response.StatusCode == HttpStatusCode.NotFound)
                        return null;
                    response.EnsureSuccessStatusCode();
                    return response.Content.ReadAsStringAsync().Result;
                }
            }
            catch (Exception exception)
            {
                if (IsNetworkFailure(exception))
                    return null;
                throw;
            }
        }

        private void DownloadChunk(ChunkRecord chunk, string destination,
            long completedBefore, long totalBytes)
        {
            Exception last = null;
            foreach (int attempt in Enumerable.Range(1, 4))
            {
                string partial = destination + ".partial";
                try
                {
                    if (File.Exists(partial)) File.Delete(partial);
                    using (HttpResponseMessage response = GetWithRetries(
                        ReleaseAssetUrl(chunk.Name),
                        HttpCompletionOption.ResponseHeadersRead))
                    using (Stream input = response.Content.ReadAsStreamAsync().Result)
                    using (FileStream output = File.Create(partial))
                    {
                        byte[] buffer = new byte[128 * 1024];
                        long downloaded = 0;
                        int read;
                        while ((read = input.Read(buffer, 0, buffer.Length)) != 0)
                        {
                            output.Write(buffer, 0, read);
                            downloaded += read;
                            long overall = completedBefore + downloaded;
                            int percent = totalBytes == 0 ? 0 : (int)Math.Min(99,
                                overall * 100 / totalBytes);
                            SetProgress(percent, FormatBytes(overall) + " of "
                                + FormatBytes(totalBytes));
                        }
                    }
                    FileInfo archiveInfo = new FileInfo(partial);
                    if (archiveInfo.Length != chunk.Size
                        || !HashFile(partial).Equals(chunk.Sha256,
                            StringComparison.OrdinalIgnoreCase))
                        throw new InvalidDataException(
                            "An update shard failed verification.");
                    if (File.Exists(destination)) File.Delete(destination);
                    File.Move(partial, destination);
                    return;
                }
                catch (Exception exception)
                {
                    last = exception;
                    try { if (File.Exists(partial)) File.Delete(partial); }
                    catch { }
                    if (attempt < 4)
                        Thread.Sleep(250 * attempt * attempt);
                }
            }
            throw new InvalidOperationException(
                "An update shard could not be downloaded and verified after four attempts.",
                last);
        }

        private static HttpResponseMessage GetWithRetries(string url,
            HttpCompletionOption completion)
        {
            Exception last = null;
            foreach (int attempt in Enumerable.Range(1, 4))
            {
                try
                {
                    HttpResponseMessage response = Http.GetAsync(url, completion).Result;
                    int status = (int)response.StatusCode;
                    if (status != 408 && status != 429 && status < 500)
                        return response;
                    response.Dispose();
                    last = new HttpRequestException(
                        "The update server temporarily returned HTTP " + status + ".");
                }
                catch (Exception exception)
                {
                    last = exception;
                    if (!IsNetworkFailure(exception)) throw;
                }
                if (attempt < 4)
                    Thread.Sleep(250 * attempt * attempt);
            }
            throw new HttpRequestException(
                "The update server did not respond after four attempts.", last);
        }

        private static string CacheBust(string url)
        {
            return url + (url.Contains("?") ? "&" : "?") + "mde="
                + DateTime.UtcNow.Ticks.ToString();
        }

        private static string FormatBytes(long bytes)
        {
            if (bytes >= 1024L * 1024L * 1024L)
                return (bytes / (1024.0 * 1024.0 * 1024.0)).ToString("0.00") + " GB";
            if (bytes >= 1024L * 1024L)
                return (bytes / (1024.0 * 1024.0)).ToString("0.0") + " MB";
            if (bytes >= 1024L)
                return (bytes / 1024.0).ToString("0.0") + " KB";
            return bytes + " bytes";
        }

        private static string ReleaseAssetUrl(string asset)
        {
            string overrideBase = Environment.GetEnvironmentVariable(
                "MDE_UPDATE_ASSET_BASE_URL");
            if (!String.IsNullOrWhiteSpace(overrideBase))
                return overrideBase.TrimEnd('/') + "/" + Uri.EscapeDataString(asset);
            return "https://github.com/" + Repository + "/releases/download/"
                + Uri.EscapeDataString(ChannelTag) + "/" + Uri.EscapeDataString(asset);
        }

        internal static string LocalPath(string root, string relative)
        {
            string safe = UpdateManifest.ValidateRelativePath(relative)
                .Replace('/', Path.DirectorySeparatorChar);
            string rootFull = Path.GetFullPath(root).TrimEnd(Path.DirectorySeparatorChar)
                + Path.DirectorySeparatorChar;
            string result = Path.GetFullPath(Path.Combine(rootFull, safe));
            if (!result.StartsWith(rootFull, StringComparison.OrdinalIgnoreCase))
                throw new InvalidDataException("Update path escaped the installation folder.");
            return result;
        }

        internal static void ReplaceAtomically(string source, string destination)
        {
            string temporary = destination + ".mde-new-"
                + Guid.NewGuid().ToString("N");
            try
            {
                File.Copy(source, temporary, true);
                if (File.Exists(destination))
                    File.Replace(temporary, destination, null, true);
                else
                    File.Move(temporary, destination);
            }
            finally
            {
                try { if (File.Exists(temporary)) File.Delete(temporary); }
                catch { }
            }
        }

        internal static void PromoteLauncherSidecar(string root)
        {
            string sidecar = Path.Combine(root, LauncherUpdateExecutable);
            string launcher = Path.Combine(root, LauncherExecutable);
            if (!File.Exists(sidecar)) return;
            if (File.Exists(launcher)
                && new FileInfo(sidecar).Length == new FileInfo(launcher).Length
                && HashFile(sidecar).Equals(HashFile(launcher),
                    StringComparison.OrdinalIgnoreCase))
                return;
            ReplaceAtomically(sidecar, launcher);
        }

        private static void CleanupOldUpdateSessions(string workRoot)
        {
            if (!Directory.Exists(workRoot)) return;
            foreach (string directory in Directory.GetDirectories(workRoot,
                "session-*", SearchOption.TopDirectoryOnly))
                TryDeleteDirectory(directory);
        }

        internal static void TryDeleteDirectory(string path)
        {
            if (!Directory.Exists(path))
                return;
            try { Directory.Delete(path, true); }
            catch { }
        }

        private void StartDeferredUpdate(string root, string work, string stage,
            UpdateManifest remote, List<FileRecord> changed, List<string> removed)
        {
            List<string> plan = new List<string>();
            plan.Add("MDE-DEFERRED-UPDATE\t1");
            plan.Add("checkOnly\t" + (checkOnly ? "1" : "0"));
            foreach (FileRecord file in changed)
                plan.Add("changed\t" + file.Path);
            foreach (string path in removed)
                plan.Add("removed\t" + path);
            foreach (string argument in gameArguments)
                plan.Add("argument\t" + Convert.ToBase64String(
                    Encoding.UTF8.GetBytes(argument)));
            File.WriteAllLines(Path.Combine(work, "deferred-plan.txt"),
                plan, new UTF8Encoding(false));
            File.WriteAllText(Path.Combine(work, "deferred-manifest.txt"),
                remote.RawText, new UTF8Encoding(false));

            string helper = Path.Combine(work, "Minecraft D Edition Update Helper.exe");
            File.Copy(Application.ExecutablePath, helper, true);
            ProcessStartInfo start = new ProcessStartInfo(helper);
            start.WorkingDirectory = root;
            start.UseShellExecute = false;
            start.CreateNoWindow = true;
            start.Arguments = "--apply-staged-update " + QuoteArgument(root)
                + " " + QuoteArgument(work) + " "
                + Process.GetCurrentProcess().Id.ToString();
            Process.Start(start);
        }

        private static bool IsNetworkFailure(Exception exception)
        {
            Exception current = exception;
            while (current != null)
            {
                if (current is HttpRequestException || current is WebException
                    || current is TaskCanceledException)
                    return true;
                current = current.InnerException;
            }
            return false;
        }

        private void LaunchGame()
        {
            string root = AppDomain.CurrentDomain.BaseDirectory;
            string game = Path.Combine(root, GameExecutable);
            if (!File.Exists(game))
                throw new FileNotFoundException("The game executable is missing.", game);
            ProcessStartInfo start = new ProcessStartInfo(game);
            start.WorkingDirectory = root;
            start.UseShellExecute = false;
            start.Arguments = String.Join(" ", gameArguments.Select(QuoteArgument));
            Process.Start(start);
        }

        internal static string QuoteArgument(string value)
        {
            if (value.Length != 0 && !value.Any(Char.IsWhiteSpace)
                && !value.Contains("\""))
                return value;
            return "\"" + value.Replace("\\", "\\\\").Replace("\"", "\\\"") + "\"";
        }

        private void SetStatus(string value)
        {
            if (InvokeRequired)
            {
                BeginInvoke(new Action<string>(SetStatus), value);
                return;
            }
            status.Text = value;
        }

        private void SetDetails(string value)
        {
            if (InvokeRequired)
            {
                BeginInvoke(new Action<string>(SetDetails), value);
                return;
            }
            details.Text = value;
        }

        private void SetProgress(int value, string detail)
        {
            if (InvokeRequired)
            {
                BeginInvoke(new Action<int, string>(SetProgress), value, detail);
                return;
            }
            progress.Style = ProgressBarStyle.Blocks;
            progress.Value = Math.Max(0, Math.Min(100, value));
            details.Text = detail;
        }
    }

    internal static class DeferredUpdateHelper
    {
        internal static int Run(string rootArgument, string workArgument,
            int parentProcessId)
        {
            try
            {
                string root = Path.GetFullPath(rootArgument)
                    .TrimEnd(Path.DirectorySeparatorChar);
                string workRoot = Path.Combine(root, ".mde-update")
                    .TrimEnd(Path.DirectorySeparatorChar)
                    + Path.DirectorySeparatorChar;
                string work = Path.GetFullPath(workArgument)
                    .TrimEnd(Path.DirectorySeparatorChar);
                if (!work.StartsWith(workRoot,
                    StringComparison.OrdinalIgnoreCase)
                    || !Path.GetFileName(work).StartsWith("session-",
                        StringComparison.OrdinalIgnoreCase))
                    throw new InvalidDataException(
                        "The deferred update folder is unsafe.");

                try
                {
                    Process parent = Process.GetProcessById(parentProcessId);
                    if (!parent.WaitForExit(60000))
                        throw new TimeoutException(
                            "The launcher did not close for its update.");
                }
                catch (ArgumentException)
                {
                    // The parent already exited between process creation and lookup.
                }

                string manifestPath = Path.Combine(work,
                    "deferred-manifest.txt");
                UpdateManifest manifest = UpdateManifest.Parse(
                    File.ReadAllText(manifestPath, Encoding.UTF8));
                string planPath = Path.Combine(work, "deferred-plan.txt");
                string[] lines = File.ReadAllLines(planPath, Encoding.UTF8);
                if (lines.Length == 0 || lines[0] != "MDE-DEFERRED-UPDATE\t1")
                    throw new InvalidDataException(
                        "The deferred update plan is invalid.");

                bool checkOnly = false;
                List<FileRecord> changed = new List<FileRecord>();
                List<string> removed = new List<string>();
                List<string> gameArguments = new List<string>();
                foreach (string line in lines.Skip(1))
                {
                    if (String.IsNullOrWhiteSpace(line)) continue;
                    string[] fields = line.Split(new[] { '\t' }, 2);
                    if (fields.Length != 2)
                        throw new InvalidDataException(
                            "The deferred update plan is malformed.");
                    if (fields[0] == "checkOnly")
                        checkOnly = fields[1] == "1";
                    else if (fields[0] == "changed")
                    {
                        string path = UpdateManifest.ValidateRelativePath(fields[1]);
                        FileRecord file;
                        if (!manifest.Files.TryGetValue(path, out file))
                            throw new InvalidDataException(
                                "The deferred plan references an unknown file.");
                        changed.Add(file);
                    }
                    else if (fields[0] == "removed")
                        removed.Add(UpdateManifest.ValidateRelativePath(fields[1]));
                    else if (fields[0] == "argument")
                        gameArguments.Add(Encoding.UTF8.GetString(
                            Convert.FromBase64String(fields[1])));
                    else
                        throw new InvalidDataException(
                            "The deferred update plan has an unknown action.");
                }

                string stage = Path.Combine(work, "stage");
                LauncherForm.ApplyWithRollback(root, work, stage,
                    changed, removed);
                LauncherForm.PromoteLauncherSidecar(root);
                LauncherForm.WriteInstalledManifest(root, manifest.RawText);
                File.WriteAllText(Path.Combine(work, "completed"),
                    manifest.Version, new UTF8Encoding(false));

                if (!checkOnly)
                {
                    string game = Path.Combine(root,
                        "Minecraft D Edition.exe");
                    if (!File.Exists(game))
                        throw new FileNotFoundException(
                            "The updated game executable is missing.", game);
                    ProcessStartInfo start = new ProcessStartInfo(game);
                    start.WorkingDirectory = root;
                    start.UseShellExecute = false;
                    start.Arguments = String.Join(" ", gameArguments.Select(
                        LauncherForm.QuoteArgument));
                    Process.Start(start);
                }
                return 0;
            }
            catch (Exception exception)
            {
                MessageBox.Show(
                    "Minecraft: D Edition could not finish its launcher update.\n\n"
                    + exception.Message
                    + "\n\nYour previous installation was restored where possible. "
                    + "Open the game again to retry.",
                    "Update failed", MessageBoxButtons.OK, MessageBoxIcon.Error);
                return 1;
            }
        }
    }

    internal static class Program
    {
        [STAThread]
        private static void Main(string[] args)
        {
            if (args.Length == 4 && String.Equals(args[0],
                "--apply-staged-update", StringComparison.OrdinalIgnoreCase))
            {
                int parentProcessId;
                if (!Int32.TryParse(args[3], out parentProcessId))
                {
                    Environment.ExitCode = 1;
                    return;
                }
                Environment.ExitCode = DeferredUpdateHelper.Run(args[1],
                    args[2], parentProcessId);
                return;
            }
            bool created;
            using (Mutex mutex = new Mutex(true,
                "Local\\MinecraftDEditionLauncher", out created))
            {
                if (!created)
                    return;
                Application.EnableVisualStyles();
                Application.SetCompatibleTextRenderingDefault(false);
                Application.Run(new LauncherForm(args));
            }
        }
    }
}
