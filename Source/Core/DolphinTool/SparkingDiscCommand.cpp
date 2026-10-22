// Copyright 2026 Dolphin-Sparking
// SPDX-License-Identifier: GPL-2.0-or-later

// dolphin-tool sparking-disc: builds the collection's own copy of a game from the player's disc.
//
// The player brings their own disc (any format Dolphin reads: ISO, WBFS, RVZ / WIA, CISO, GCZ,
// NKit). A "recipe" (made by Tools/sparking_release.py disc, delivered by the launcher's updates)
// lists every file of the original disc with its size and SHA-1, and how each file of the
// collection's version is made from them: ranges copied from the original's files, plus new
// bytes from the recipe's data file (only what isn't on the original disc: the mod's own work).
//
//   1. check: the disc is that game, version (ID) and revision, and every file is exactly the
//      original's (no file missing, extra, changed or damaged). Any container works: the check
//      is on the files inside, which are the same in every good copy.
//   2. build: the collection's version as a virtual disc on top of the player's (Dolphin's
//      DirectoryBlob, as for Riivolution mods), written out as one RVZ (or ISO). The layout only
//      depends on the files, so every player gets a byte-identical image.
//
// Output on stdout, one line each (for the launcher; flushed as they happen):
//   stage check|build           progress <0..1>
//   error <code> <details>      done <output path>
// Error codes: open, not_disc, wrong_game, wrong_revision, modified, read, bad_recipe, write.

#include "DolphinTool/SparkingDiscCommand.h"

#include <algorithm>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <map>
#include <memory>
#include <optional>
#include <set>
#include <string>
#include <vector>

#include <OptionParser.h>
#include <fmt/format.h>
#include <fmt/ranges.h>
#include <picojson.h>

#include "Common/CommonTypes.h"
#include "Common/Crypto/SHA1.h"
#include "Common/FileUtil.h"
#include "Common/IOFile.h"
#include "Common/StringUtil.h"
#include "DiscIO/Blob.h"
#include "DiscIO/DirectoryBlob.h"
#include "DiscIO/DiscUtils.h"
#include "DiscIO/Filesystem.h"
#include "DiscIO/Volume.h"
#include "DiscIO/WIABlob.h"
#include "UICommon/UICommon.h"

namespace DolphinTool
{
namespace
{
// A file of the disc's game partition, named as dolphin-tool extract writes it ("sys/main.dol",
// "files/<path>"). The small system files are kept in memory, the rest is read from the disc.
struct DiscFile
{
  u64 offset = 0;  // in the partition (when not in memory)
  u64 size = 0;
  bool in_memory = false;
  std::vector<u8> bytes;
};

struct Segment
{
  bool from_source = false;  // else: from the recipe's data file
  size_t source_index = 0;
  u64 offset = 0;
  u64 length = 0;
};

struct Entry
{
  std::string path;
  u64 size = 0;
  std::string sha1;
};

struct Recipe
{
  std::string name;
  std::string game_id;
  int revision = 0;
  std::vector<Entry> source;
  std::vector<Entry> target;
  std::vector<std::string> empty_dirs;                 // "files/<path>/" with nothing inside
  std::map<std::string, std::vector<Segment>> built;   // target files that aren't the original's
  std::string data_path;
  u64 data_size = 0;
};

void Say(const std::string& line)
{
  std::fputs((line + "\n").c_str(), stdout);
  std::fflush(stdout);
}

int Fail(const std::string& code, const std::string& details)
{
  Say(fmt::format("error {} {}", code, details));
  return EXIT_FAILURE;
}

std::string Hex(const Common::SHA1::Digest& digest)
{
  return fmt::format("{:02x}", fmt::join(digest, ""));
}

// The disc header's bytes that differ between good copies of the same disc: NKit's own data
// (0x200-0x21B) and the DOL / FST positions (0x420-0x42F, rewritten when a disc is rebuilt).
// They're zeroed before boot.bin is hashed (Tools/sparking_release.py does the same).
std::vector<u8> MaskedHeader(std::vector<u8> header)
{
  for (size_t i = 0x200; i < 0x21C && i < header.size(); ++i)
    header[i] = 0;
  for (size_t i = 0x420; i < 0x430 && i < header.size(); ++i)
    header[i] = 0;
  return header;
}

void AddFiles(const DiscIO::FileInfo& dir, const std::string& prefix,
              std::map<std::string, DiscFile>* files, std::vector<std::string>* empty_dirs)
{
  bool any = false;
  for (const DiscIO::FileInfo& child : dir)
  {
    any = true;
    const std::string path = prefix + child.GetName();
    if (child.IsDirectory())
    {
      AddFiles(child, path + "/", files, empty_dirs);
    }
    else
    {
      DiscFile f;
      f.offset = child.GetOffset();
      f.size = child.GetSize();
      (*files)[path] = std::move(f);
    }
  }
  if (!any && prefix != "files/")
    empty_dirs->push_back(prefix);
}

bool ReadMemory(const DiscIO::Volume& volume, const DiscIO::Partition& partition, u64 offset,
                u64 size, DiscFile* f)
{
  f->in_memory = true;
  f->size = size;
  f->bytes.resize(size);
  return volume.Read(offset, size, f->bytes.data(), partition);
}

// Every file of the game partition. False if the disc's system area can't be read.
bool ListDisc(const DiscIO::Volume& volume, const DiscIO::Partition& partition,
              std::map<std::string, DiscFile>* files, std::vector<std::string>* empty_dirs)
{
  DiscFile boot, bi2, apploader, dol;
  if (!ReadMemory(volume, partition, DiscIO::DISCHEADER_ADDRESS, DiscIO::DISCHEADER_SIZE, &boot) ||
      !ReadMemory(volume, partition, DiscIO::BI2_ADDRESS, DiscIO::BI2_SIZE, &bi2))
  {
    return false;
  }
  const std::optional<u64> apploader_size = DiscIO::GetApploaderSize(volume, partition);
  const std::optional<u64> dol_offset = DiscIO::GetBootDOLOffset(volume, partition);
  if (!apploader_size || !dol_offset)
    return false;
  const std::optional<u32> dol_size = DiscIO::GetBootDOLSize(volume, partition, *dol_offset);
  if (!dol_size ||
      !ReadMemory(volume, partition, DiscIO::APPLOADER_ADDRESS, *apploader_size, &apploader))
  {
    return false;
  }
  dol.offset = *dol_offset;
  dol.size = *dol_size;
  (*files)["sys/boot.bin"] = std::move(boot);
  (*files)["sys/bi2.bin"] = std::move(bi2);
  (*files)["sys/apploader.img"] = std::move(apploader);
  (*files)["sys/main.dol"] = std::move(dol);

  const DiscIO::FileSystem* fs = volume.GetFileSystem(partition);
  if (fs && fs->IsValid())
    AddFiles(fs->GetRoot(), "files/", files, empty_dirs);
  return true;
}

class Progress
{
public:
  explicit Progress(u64 total) : m_total(std::max<u64>(total, 1)) {}
  void Add(u64 bytes) { Set(static_cast<double>(m_done += bytes) / static_cast<double>(m_total)); }
  static void Set(double fraction)
  {
    static auto last = std::chrono::steady_clock::time_point{};
    const auto now = std::chrono::steady_clock::now();
    if (fraction < 1.0 && now - last < std::chrono::milliseconds(250))
      return;
    last = now;
    Say(fmt::format("progress {:.4f}", std::min(fraction, 1.0)));
  }

private:
  u64 m_total;
  u64 m_done = 0;
};

std::optional<std::string> HashFile(const DiscIO::Volume& volume,
                                    const DiscIO::Partition& partition, const std::string& path,
                                    const DiscFile& f, Progress* progress)
{
  auto ctx = Common::SHA1::CreateContext();
  if (f.in_memory)
  {
    const std::vector<u8> bytes = path == "sys/boot.bin" ? MaskedHeader(f.bytes) : f.bytes;
    ctx->Update(bytes);
    progress->Add(f.size);
    return Hex(ctx->Finish());
  }
  std::vector<u8> buffer(1 << 20);
  for (u64 at = 0; at < f.size;)
  {
    const u64 n = std::min<u64>(buffer.size(), f.size - at);
    if (!volume.Read(f.offset + at, n, buffer.data(), partition))
      return std::nullopt;
    ctx->Update(buffer.data(), static_cast<size_t>(n));
    at += n;
    progress->Add(n);
  }
  return Hex(ctx->Finish());
}

// --- The recipe ---------------------------------------------------------------------------

std::optional<std::vector<Entry>> ParseEntries(const picojson::value& v)
{
  if (!v.is<picojson::array>())
    return std::nullopt;
  std::vector<Entry> out;
  for (const picojson::value& item : v.get<picojson::array>())
  {
    if (!item.is<picojson::array>())
      return std::nullopt;
    const auto& a = item.get<picojson::array>();
    if (a.size() != 3 || !a[0].is<std::string>() || !a[1].is<double>() ||
        !a[2].is<std::string>())
    {
      return std::nullopt;
    }
    out.push_back({a[0].get<std::string>(), static_cast<u64>(a[1].get<double>()),
                   a[2].get<std::string>()});
  }
  return out;
}

std::optional<std::string> LoadRecipe(const std::string& path, Recipe* r)
{
  std::string text;
  if (!File::ReadFileToString(path, text))
    return "can't read " + path;
  picojson::value root;
  const std::string err = picojson::parse(root, text);
  if (!err.empty() || !root.is<picojson::object>())
    return "not JSON: " + err;
  const auto& o = root.get<picojson::object>();
  auto get = [&o](const char* key) -> const picojson::value& {
    static const picojson::value null_value;
    const auto it = o.find(key);
    return it == o.end() ? null_value : it->second;
  };
  if (!get("format").is<double>() || get("format").get<double>() != 1)
    return "unknown recipe format (a newer launcher is needed)";
  if (!get("game_id").is<std::string>() || !get("revision").is<double>())
    return "no game_id / revision";
  r->game_id = get("game_id").get<std::string>();
  r->revision = static_cast<int>(get("revision").get<double>());
  r->name = get("name").is<std::string>() ? get("name").get<std::string>() : r->game_id;

  const auto source = ParseEntries(get("source"));
  const auto target = ParseEntries(get("target"));
  if (!source || !target)
    return "bad source / target lists";
  r->source = *source;
  r->target = *target;
  if (get("empty_dirs").is<picojson::array>())
  {
    for (const picojson::value& d : get("empty_dirs").get<picojson::array>())
    {
      if (d.is<std::string>())
        r->empty_dirs.push_back(d.get<std::string>());
    }
  }

  if (get("data").is<std::string>())
  {
    std::string dir;
    SplitPath(path, &dir, nullptr, nullptr);
    r->data_path = dir + get("data").get<std::string>();
    const u64 have = File::GetSize(r->data_path);
    r->data_size = get("data_size").is<double>() ? static_cast<u64>(get("data_size").get<double>()) : 0;
    if (have != r->data_size)
      return fmt::format("{} is {} bytes, not {} (not fully downloaded?)", r->data_path, have,
                         r->data_size);
  }

  std::map<std::string, size_t> source_index;
  for (size_t i = 0; i < r->source.size(); ++i)
    source_index[r->source[i].path] = i;

  const picojson::value& built = get("files");
  if (!built.is<picojson::object>() && !built.is<picojson::null>())
    return "bad files";
  if (built.is<picojson::object>())
  {
    for (const auto& [file, segments_v] : built.get<picojson::object>())
    {
      if (!segments_v.is<picojson::array>())
        return "bad segments of " + file;
      std::vector<Segment> segments;
      for (const picojson::value& s : segments_v.get<picojson::array>())
      {
        if (!s.is<picojson::array>())
          return "bad segment in " + file;
        const auto& a = s.get<picojson::array>();
        Segment seg;
        if (a.size() == 4 && a[0].is<std::string>() && a[0].get<std::string>() == "s" &&
            a[1].is<double>() && a[2].is<double>() && a[3].is<double>())
        {
          seg.from_source = true;
          seg.source_index = static_cast<size_t>(a[1].get<double>());
          seg.offset = static_cast<u64>(a[2].get<double>());
          seg.length = static_cast<u64>(a[3].get<double>());
          if (seg.source_index >= r->source.size() ||
              seg.offset + seg.length > r->source[seg.source_index].size)
          {
            return "segment outside its source in " + file;
          }
        }
        else if (a.size() == 3 && a[0].is<std::string>() && a[0].get<std::string>() == "n" &&
                 a[1].is<double>() && a[2].is<double>())
        {
          seg.offset = static_cast<u64>(a[1].get<double>());
          seg.length = static_cast<u64>(a[2].get<double>());
          if (seg.offset + seg.length > r->data_size)
            return "segment outside the data file in " + file;
        }
        else
        {
          return "bad segment in " + file;
        }
        segments.push_back(seg);
      }
      r->built[file] = std::move(segments);
    }
  }

  // Every target file: built from segments that add up to its size, or the original's file.
  for (const Entry& t : r->target)
  {
    const auto it = r->built.find(t.path);
    if (it != r->built.end())
    {
      u64 total = 0;
      for (const Segment& s : it->second)
        total += s.length;
      if (total != t.size)
        return "segments of " + t.path + " don't add up to its size";
    }
    else
    {
      const auto s = source_index.find(t.path);
      if (s == source_index.end() || r->source[s->second].size != t.size ||
          r->source[s->second].sha1 != t.sha1)
      {
        return t.path + " is neither built nor the original's file";
      }
    }
    if (t.path.rfind("sys/", 0) != 0 && t.path.rfind("files/", 0) != 0)
      return "unknown place for " + t.path;
  }
  for (const char* sys : {"sys/boot.bin", "sys/bi2.bin", "sys/apploader.img", "sys/main.dol"})
  {
    if (std::none_of(r->target.begin(), r->target.end(),
                     [sys](const Entry& e) { return e.path == sys; }))
    {
      return std::string("no ") + sys + " in the target";
    }
  }
  return std::nullopt;
}

// --- Building ------------------------------------------------------------------------------

struct Builder
{
  const Recipe& recipe;
  const DiscIO::Volume* volume;
  DiscIO::Partition partition;
  std::map<std::string, DiscFile> files;  // the player's disc
  bool ok = true;

  const DiscFile& Source(size_t index) const { return files.at(recipe.source[index].path); }

  std::vector<DiscIO::BuilderContentSource> Sources(const std::string& path) const
  {
    std::vector<DiscIO::BuilderContentSource> out;
    const auto it = recipe.built.find(path);
    if (it == recipe.built.end())
    {
      const DiscFile& f = files.at(path);
      AddRange(f, 0, f.size, 0, &out);
      return out;
    }
    u64 at = 0;
    for (const Segment& s : it->second)
    {
      if (s.from_source)
        AddRange(Source(s.source_index), s.offset, s.length, at, &out);
      else
        out.push_back({at, s.length, DiscIO::ContentFile{recipe.data_path, s.offset}});
      at += s.length;
    }
    return out;
  }

  void AddRange(const DiscFile& f, u64 offset, u64 length, u64 at,
                std::vector<DiscIO::BuilderContentSource>* out) const
  {
    if (length == 0)
      return;
    if (f.in_memory)
    {
      auto bytes = std::make_shared<std::vector<u8>>(f.bytes.begin() + static_cast<s64>(offset),
                                                     f.bytes.begin() +
                                                         static_cast<s64>(offset + length));
      out->push_back({at, length, bytes});
    }
    else
    {
      out->push_back({at, length, DiscIO::ContentVolume{f.offset + offset, partition}});
    }
  }

  // A small system file as bytes (boot.bin, bi2.bin, apploader.img).
  std::vector<u8> Bytes(const std::string& path)
  {
    const auto it = recipe.built.find(path);
    if (it == recipe.built.end())
      return files.at(path).bytes;
    std::vector<u8> out;
    for (const Segment& s : it->second)
    {
      const size_t at = out.size();
      out.resize(at + s.length);
      if (s.from_source)
      {
        const DiscFile& f = Source(s.source_index);
        if (f.in_memory)
          std::copy_n(f.bytes.begin() + static_cast<s64>(s.offset), s.length, out.begin() + at);
        else
          ok &= volume->Read(f.offset + s.offset, s.length, out.data() + at, partition);
      }
      else
      {
        File::IOFile data(recipe.data_path, "rb");
        ok &= data.Seek(static_cast<s64>(s.offset), File::SeekOrigin::Begin) &&
              data.ReadBytes(out.data() + at, s.length);
      }
    }
    return out;
  }

  void Sys(std::vector<DiscIO::FSTBuilderNode>* nodes)
  {
    for (DiscIO::FSTBuilderNode& node : *nodes)
    {
      const std::string path = "sys/" + node.m_filename;
      if (!recipe.built.contains(path))
        continue;
      std::vector<u8> bytes = Bytes(path);
      node.m_size = bytes.size();
      std::vector<DiscIO::BuilderContentSource> content;
      content.push_back({0, bytes.size(), std::make_shared<std::vector<u8>>(std::move(bytes))});
      node.m_content = std::move(content);
    }
  }

  static DiscIO::FSTBuilderNode* Folder(std::vector<DiscIO::FSTBuilderNode>* nodes,
                                        const std::string& name)
  {
    for (DiscIO::FSTBuilderNode& n : *nodes)
    {
      if (n.m_filename == name && n.IsFolder())
        return &n;
    }
    nodes->push_back(DiscIO::FSTBuilderNode{name, 0, std::vector<DiscIO::FSTBuilderNode>{}});
    return &nodes->back();
  }

  static std::vector<DiscIO::FSTBuilderNode>* Place(std::vector<DiscIO::FSTBuilderNode>* root,
                                                    const std::string& relative,
                                                    std::string* leaf)
  {
    std::vector<DiscIO::FSTBuilderNode>* at = root;
    size_t start = 0;
    for (size_t slash; (slash = relative.find('/', start)) != std::string::npos; start = slash + 1)
      at = &Folder(at, relative.substr(start, slash - start))->GetFolderContent();
    *leaf = relative.substr(start);
    return at;
  }

  void Fst(std::vector<DiscIO::FSTBuilderNode>* nodes, DiscIO::FSTBuilderNode* dol)
  {
    std::vector<DiscIO::FSTBuilderNode> root;
    for (const Entry& t : recipe.target)
    {
      if (t.path.rfind("files/", 0) != 0)
        continue;
      std::string leaf;
      std::vector<DiscIO::FSTBuilderNode>* folder = Place(&root, t.path.substr(6), &leaf);
      folder->push_back(DiscIO::FSTBuilderNode{leaf, t.size, Sources(t.path)});
    }
    for (const std::string& d : recipe.empty_dirs)
    {
      std::string leaf;
      Place(&root, d.substr(6), &leaf);   // (ends in "/": the folder itself, no file)
    }
    *nodes = std::move(root);

    dol->m_size = recipe.target[TargetIndex("sys/main.dol")].size;
    dol->m_content = Sources("sys/main.dol");
  }

  size_t TargetIndex(const std::string& path) const
  {
    for (size_t i = 0; i < recipe.target.size(); ++i)
    {
      if (recipe.target[i].path == path)
        return i;
    }
    return 0;  // (checked when the recipe was loaded)
  }
};
}  // namespace

int SparkingDiscCommand(const std::vector<std::string>& args)
{
  optparse::OptionParser parser;
  parser.usage("usage: sparking-disc -i DISC -r RECIPE [-o OUTPUT] [-f rvz|iso] [-u USER] | "
               "sparking-disc -i DISC --list");
  parser.add_option("-i", "--input").action("store").help("The player's disc image.");
  parser.add_option("-r", "--recipe").action("store").help("recipe.json.");
  parser.add_option("-o", "--output").action("store").help("Where to write the built disc.");
  parser.add_option("-f", "--format").action("store").set_default("rvz").help("rvz or iso.");
  parser.add_option("-u", "--user").action("store").help("Dolphin user folder (temporary files).");
  parser.add_option("-c", "--check").action("store_true").help("Only check the disc.");
  parser.add_option("-l", "--list")
      .action("store_true")
      .help("Print the disc's ID, revision and files (path, size, SHA-1) as JSON.");
  const optparse::Values& options = parser.parse_args(args);

  UICommon::SetUserDirectory(options["user"]);
  UICommon::Init();

  if (!options.is_set("input"))
    return Fail("usage", "no -i");
  const std::string input = options["input"];

  std::unique_ptr<DiscIO::VolumeDisc> volume = DiscIO::CreateDisc(input);
  if (!volume)
    return Fail("open", "not a disc image Dolphin can read: " + input);
  if (volume->GetVolumeType() != DiscIO::Platform::WiiDisc &&
      volume->GetVolumeType() != DiscIO::Platform::GameCubeDisc)
  {
    return Fail("not_disc", "not a Wii or GameCube disc");
  }
  const DiscIO::Partition partition = volume->GetGamePartition();
  const std::string game_id = volume->GetGameID(partition);
  const int revision = volume->GetRevision(partition).value_or(0);

  std::map<std::string, DiscFile> files;
  std::vector<std::string> empty_dirs;
  if (!ListDisc(*volume, partition, &files, &empty_dirs))
    return Fail("read", "the disc's system area can't be read (damaged copy?)");

  if (options.get("list"))
  {
    u64 total = 0;
    for (const auto& [path, f] : files)
      total += f.size;
    Progress progress(total);
    picojson::array list;
    for (const auto& [path, f] : files)
    {
      const auto sha1 = HashFile(*volume, partition, path, f, &progress);
      if (!sha1)
        return Fail("read", path + " can't be read (damaged copy?)");
      list.emplace_back(picojson::array{picojson::value(path),
                                        picojson::value(static_cast<double>(f.size)),
                                        picojson::value(*sha1)});
    }
    picojson::array dirs;
    for (const std::string& d : empty_dirs)
      dirs.emplace_back(d);
    picojson::object o;
    o["game_id"] = picojson::value(game_id);
    o["revision"] = picojson::value(static_cast<double>(revision));
    o["files"] = picojson::value(list);
    o["empty_dirs"] = picojson::value(dirs);
    Say("list " + picojson::value(o).serialize());
    return EXIT_SUCCESS;
  }

  if (!options.is_set("recipe"))
    return Fail("usage", "no -r");
  Recipe recipe;
  if (const auto err = LoadRecipe(options["recipe"], &recipe))
    return Fail("bad_recipe", *err);

  // 1. The check.
  Say("stage check");
  if (game_id != recipe.game_id)
    return Fail("wrong_game", game_id);
  if (revision != recipe.revision)
    return Fail("wrong_revision", std::to_string(revision));
  std::set<std::string> on_disc;
  for (const auto& [path, f] : files)
    on_disc.insert(path);
  u64 total = 0;
  for (const Entry& e : recipe.source)
  {
    const auto it = files.find(e.path);
    if (it == files.end())
      return Fail("modified", e.path + " is missing");
    if (it->second.size != e.size)
      return Fail("modified", e.path + " has another size");
    on_disc.erase(e.path);
    total += e.size;
  }
  if (!on_disc.empty())
    return Fail("modified", *on_disc.begin() + " isn't on the original disc");
  Progress progress(total);
  for (const Entry& e : recipe.source)
  {
    const auto sha1 = HashFile(*volume, partition, e.path, files.at(e.path), &progress);
    if (!sha1)
      return Fail("read", e.path + " can't be read (damaged copy?)");
    if (*sha1 != e.sha1)
      return Fail("modified", e.path + " isn't the original's");
  }
  Progress::Set(1.0);
  if (options.get("check"))
  {
    Say("done check");
    return EXIT_SUCCESS;
  }

  // 2. The build.
  if (!options.is_set("output"))
    return Fail("usage", "no -o");
  const std::string output = options["output"];
  const std::string format = options["format"];
  if (format != "rvz" && format != "iso")
    return Fail("usage", "-f must be rvz or iso");

  Say("stage build");
  Builder builder{recipe, volume.get(), partition, std::move(files)};
  std::unique_ptr<DiscIO::DirectoryBlobReader> blob = DiscIO::DirectoryBlobReader::Create(
      std::move(volume),
      [&builder](std::vector<DiscIO::FSTBuilderNode>* nodes) { builder.Sys(nodes); },
      [&builder](std::vector<DiscIO::FSTBuilderNode>* nodes, DiscIO::FSTBuilderNode* dol) {
        builder.Fst(nodes, dol);
      });
  if (!blob || !builder.ok)
    return Fail("read", "couldn't put the disc together");

  File::Delete(output);
  File::CreateFullPath(output);
  const auto callback = [](const std::string&, float percent) {
    Progress::Set(static_cast<double>(percent));
    return true;
  };
  const bool written =
      format == "iso" ?
          DiscIO::ConvertToPlain(blob.get(), input, output, callback) :
          DiscIO::ConvertToWIAOrRVZ(blob.get(), input, output, true,
                                    DiscIO::WIARVZCompressionType::Zstd, 5, 128 * 1024, callback);
  if (!written)
  {
    File::Delete(output);
    return Fail("write", "couldn't write " + output + " (disk full?)");
  }
  Progress::Set(1.0);
  Say("done " + output);
  return EXIT_SUCCESS;
}
}  // namespace DolphinTool
