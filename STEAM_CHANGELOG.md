[h1]Minidoracat Pack & Throw for B42 42.22.2-0.5.9[/h1]
[i]2026-11-25[/i]

[b]English summary[/b]
[list]
[*] Servers with many capsule records no longer freeze for about half a second whenever a capsule changes. The list behind the admin panel used to be rewritten in full each time; now only the changed entries are rewritten.
[/list]

[h3]🔧 修正[/h3]
[list]
[*] [b]膠囊紀錄多的伺服器，不會再動不動卡頓半秒[/b]：伺服器替管理面板整理一份所有膠囊與帕魯球的清單；之前只要有一顆變動（連玩家帶著的膠囊被看到都算），下一秒就把整份清單重寫一次（最多每秒一次）。收放過幾千次的伺服器，每次重寫都讓伺服器停住約半秒，人多時容易延遲或出現「伺服器太忙」。現在只重寫有變動的那幾筆，一次約百分之一秒。單人存檔一樣適用；從第一版就有，紀錄越多越明顯。
[/list]
