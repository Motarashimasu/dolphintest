// Copyright 2026 Dolphin-Sparking Project
// SPDX-License-Identifier: GPL-2.0-or-later

#include "DolphinNoGUI/SparkingNet.h"

#include <algorithm>
#include <array>
#include <cctype>
#include <string_view>

#ifdef _WIN32
// clang-format off
#include <winsock2.h>
#include <ws2tcpip.h>
#include <iphlpapi.h>
// clang-format on
#include <vector>
#include "Common/StringUtil.h"
#elif defined(__linux__)
#include <fstream>
#include <sstream>
#include <sys/stat.h>
#endif

namespace Sparking
{
namespace
{
[[maybe_unused]] bool LooksVirtual(std::string description)
{
  std::ranges::transform(description, description.begin(),
                         [](unsigned char c) { return static_cast<char>(std::tolower(c)); });
  static constexpr std::array<std::string_view, 14> keywords = {
      "virtual", "vpn",       "tap-",      "tap ",    "tunnel", "wireguard", "zerotier",
      "tailscale", "hamachi", "radmin",    "openvpn", "wintun", "loopback",  "vethernet"};
  return std::ranges::any_of(keywords, [&](std::string_view k) {
    return description.find(k) != std::string::npos;
  });
}
}  // namespace

#ifdef _WIN32
std::string DetectLinkType()
{
  // The adapter Windows would use to reach a public address = the one carrying netplay traffic.
  sockaddr_in destination{};
  destination.sin_family = AF_INET;
  inet_pton(AF_INET, "1.1.1.1", &destination.sin_addr);
  DWORD index = 0;
  if (GetBestInterfaceEx(reinterpret_cast<sockaddr*>(&destination), &index) != NO_ERROR)
    return "unknown";

  ULONG size = 16 * 1024;
  std::vector<unsigned char> buffer;
  ULONG result = ERROR_BUFFER_OVERFLOW;
  for (int attempt = 0; attempt < 3 && result == ERROR_BUFFER_OVERFLOW; ++attempt)
  {
    buffer.resize(size);
    result = GetAdaptersAddresses(AF_UNSPEC,
                                  GAA_FLAG_SKIP_ANYCAST | GAA_FLAG_SKIP_MULTICAST |
                                      GAA_FLAG_SKIP_DNS_SERVER,
                                  nullptr, reinterpret_cast<IP_ADAPTER_ADDRESSES*>(buffer.data()),
                                  &size);
  }
  if (result != NO_ERROR)
    return "unknown";

  for (auto* a = reinterpret_cast<IP_ADAPTER_ADDRESSES*>(buffer.data()); a; a = a->Next)
  {
    if (a->IfIndex != index && a->Ipv6IfIndex != index)
      continue;
    const std::string description =
        WStringToUTF8(a->Description ? a->Description : L"") + " " +
        WStringToUTF8(a->FriendlyName ? a->FriendlyName : L"");
    if (LooksVirtual(description))
      return "virtual";
    switch (a->IfType)
    {
    case IF_TYPE_ETHERNET_CSMACD:
      return "wired";
    case IF_TYPE_IEEE80211:
    case 243:  // IF_TYPE_WWANPP (mobile broadband)
    case 244:  // IF_TYPE_WWANPP2
      return "wireless";
    case IF_TYPE_TUNNEL:
    case IF_TYPE_PPP:
    case IF_TYPE_PROP_VIRTUAL:
      return "virtual";
    default:
      return "unknown";
    }
  }
  return "unknown";
}
#elif defined(__linux__)
std::string DetectLinkType()
{
  // Default route (destination 00000000) -> interface name.
  std::ifstream routes("/proc/net/route");
  std::string line, iface;
  std::getline(routes, line);  // header
  while (std::getline(routes, line))
  {
    std::istringstream fields(line);
    std::string name, destination;
    if (fields >> name >> destination && destination == "00000000")
    {
      iface = name;
      break;
    }
  }
  if (iface.empty())
    return "unknown";
  const auto exists = [](const std::string& path) {
    struct stat st;
    return stat(path.c_str(), &st) == 0;
  };
  const std::string base = "/sys/class/net/" + iface;
  if (exists(base + "/wireless") || exists(base + "/phy80211"))
    return "wireless";
  if (!exists(base + "/device") || LooksVirtual(iface))
    return "virtual";  // tun/tap/wg/docker/veth... have no physical device
  return "wired";
}
#else
std::string DetectLinkType()
{
  return "unknown";
}
#endif
}  // namespace Sparking
