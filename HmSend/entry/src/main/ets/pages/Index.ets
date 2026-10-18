// 主页面：底部四 Tab（接收 / 发送 / 历史 / 设置），与 PC 端页面结构对齐。
// 当前为 M0：接收页真实展示组播发现的设备，设置页可改别名/PIN/HTTPS 并即时重启服务。
import { settingsService, Settings } from '../service/SettingsService';
import { deviceRegistry } from '../service/DeviceRegistry';
import { httpServer } from '../service/HttpServer';
import { discoveryService } from '../service/DiscoveryService';
import { Log } from '../common/Logger';
import { Const } from '../common/Constants';
import { DeviceItem } from '../model/Types';

const GREEN: string = '#16A34A';
const BG: string = '#F3F5F7';
const CARD: string = '#FFFFFF';
const TEXT: string = '#1A1D21';
const SUB: string = '#6B7280';
const LINE: string = '#E5E7EB';

@Entry
@Component
struct Index {
  @State devices: DeviceItem[] = [];
  @State currentTab: number = 0;

  @State alias: string = '';
  @State port: number = Const.DEFAULT_PORT;
  @State protocolText: string = 'https';
  @State fingerprint: string = '';
  @State httpsOn: boolean = true;
  @State pin: string = '';
  @State autoAccept: boolean = false;
  @State serverState: string = '';

  private timerId: number = -1;

  aboutToAppear(): void {
    deviceRegistry.setListener(() => {
      this.devices = deviceRegistry.list();
    });
    this.refreshLocal();
    this.devices = deviceRegistry.list();
    // 每 5 秒刷新一次，保证超时设备自动消失
    this.timerId = setInterval(() => {
      deviceRegistry.purgeOffline();
      this.devices = deviceRegistry.list();
    }, 5000);
  }

  aboutToDisappear(): void {
    if (this.timerId !== -1) {
      clearInterval(this.timerId);
      this.timerId = -1;
    }
  }

  private refreshLocal(): void {
    const s: Settings = settingsService.value;
    this.alias = s.alias;
    this.port = s.port;
    this.protocolText = s.https ? 'https' : 'http';
    this.fingerprint = settingsService.effectiveFingerprint();
    this.httpsOn = s.https;
    this.pin = s.pin;
    this.autoAccept = s.autoAccept;
    this.serverState = httpServer.isRunning() ? (s.https ? 'HTTPS 服务运行中' : 'HTTP 服务运行中') : '服务未启动';
  }

  @Builder
  SectionTitle(title: string, desc: string) {
    Column({ space: 4 }) {
      Text(title).fontSize(15).fontWeight(FontWeight.Medium).fontColor(TEXT)
      Text(desc).fontSize(12).fontColor(SUB)
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
  }

  @Builder
  LocalCard() {
    Column({ space: 12 }) {
      Row() {
        Text(this.alias).fontSize(17).fontWeight(FontWeight.Medium).fontColor(TEXT)
        Blank()
        Text(this.protocolText === 'https' ? '加密' : '明文')
          .fontSize(11)
          .fontColor(this.protocolText === 'https' ? GREEN : SUB)
          .backgroundColor(this.protocolText === 'https' ? '#E8F6EE' : '#F1F2F4')
          .borderRadius(8)
          .padding({ left: 8, right: 8, top: 2, bottom: 2 })
      }
      .width('100%')

      Text(`端口 ${this.port} · ${this.serverState}`)
        .fontSize(12).fontColor(SUB).width('100%')

      Text(`指纹 ${this.fingerprint}`)
        .fontSize(11).fontColor(SUB).width('100%').maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .alignItems(HorizontalAlign.Start)
    .padding(16)
    .backgroundColor(CARD)
    .borderRadius(12)
    .border({ width: 1, color: LINE })
    .width('100%')
  }

  @Builder
  DeviceRow(item: DeviceItem) {
    Row({ space: 12 }) {
      Stack() {
        Text(item.alias.length > 0 ? item.alias.substring(0, 1) : '?')
          .fontSize(16).fontColor(Color.White).fontWeight(FontWeight.Medium)
      }
      .width(40).height(40).borderRadius(10).backgroundColor(GREEN)

      Column({ space: 4 }) {
        Text(item.alias).fontSize(14).fontWeight(FontWeight.Medium).fontColor(TEXT)
        Text(`${item.ip} · ${item.platformLabel()} · ${item.protocol}`)
          .fontSize(11).fontColor(SUB).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      Text('在线').fontSize(11).fontColor(GREEN)
    }
    .padding(12)
    .backgroundColor(CARD)
    .borderRadius(12)
    .border({ width: 1, color: LINE })
    .width('100%')
  }

  @Builder
  EmptyDevices() {
    Column({ space: 8 }) {
      Text('正在搜索附近设备…').fontSize(14).fontWeight(FontWeight.Medium).fontColor(TEXT)
      Text('确保对方设备已打开快传，并连接同一 Wi-Fi').fontSize(12).fontColor(SUB)
    }
    .width('100%')
    .padding({ top: 32, bottom: 32 })
    .alignItems(HorizontalAlign.Center)
  }

  @Builder
  ReceiveTab() {
    Scroll() {
      Column({ space: 16 }) {
        this.SectionTitle('本机设备', '其他设备通过这个名字找到你')
        this.LocalCard()

        this.SectionTitle('附近设备', `已发现 ${this.devices.length} 台`)
        Column({ space: 8 }) {
          if (this.devices.length === 0) {
            this.EmptyDevices()
          } else {
            ForEach(this.devices, (item: DeviceItem) => {
              this.DeviceRow(item)
            }, (item: DeviceItem) => item.fingerprint)
          }
        }
        .width('100%')
      }
      .padding(16)
      .width('100%')
    }
    .backgroundColor(BG)
    .width('100%')
    .height('100%')
  }

  @Builder
  SendTab() {
    Column({ space: 16 }) {
      this.SectionTitle('选择目标设备', '点击切换是否勾选（可多选，群发给所有勾选设备）')
      if (this.devices.length === 0) {
        this.EmptyDevices()
      } else {
        Flex({ wrap: FlexWrap.Wrap }) {
          ForEach(this.devices, (item: DeviceItem) => {
            Text(item.alias)
              .fontSize(13)
              .fontColor(TEXT)
              .padding({ left: 12, right: 12, top: 8, bottom: 8 })
              .backgroundColor(CARD)
              .borderRadius(16)
              .border({ width: 1, color: LINE })
              .margin({ right: 8, bottom: 8 })
          }, (item: DeviceItem) => item.fingerprint)
        }
        .width('100%')
      }
      Text('文件选择与传输在下一步实现（M1）').fontSize(12).fontColor(SUB)
    }
    .padding(16)
    .alignItems(HorizontalAlign.Start)
    .backgroundColor(BG)
    .width('100%')
    .height('100%')
  }

  @Builder
  HistoryTab() {
    Column({ space: 8 }) {
      Text('暂无传输记录').fontSize(14).fontWeight(FontWeight.Medium).fontColor(TEXT)
      Text('收发文件完成后会自动记录在这里').fontSize(12).fontColor(SUB)
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .backgroundColor(BG)
  }

  @Builder
  SettingRow(label: string, hint: string) {
    Column({ space: 4 }) {
      Text(label).fontSize(14).fontColor(TEXT)
      Text(hint).fontSize(11).fontColor(SUB)
    }
    .alignItems(HorizontalAlign.Start)
    .layoutWeight(1)
  }

  @Builder
  SettingsTab() {
    Scroll() {
      Column({ space: 16 }) {
        this.SectionTitle('设备身份', '对方看到的设备名')

        Column({ space: 8 }) {
          Text('本机显示名').fontSize(13).fontColor(TEXT)
          TextInput({ text: this.alias, placeholder: '例如：我的手机' })
            .onChange((v: string) => {
              this.alias = v;
            })
            .backgroundColor('#F7F8FA')
            .borderRadius(8)
        }
        .alignItems(HorizontalAlign.Start)
        .padding(16)
        .backgroundColor(CARD)
        .borderRadius(12)
        .border({ width: 1, color: LINE })
        .width('100%')

        this.SectionTitle('连接与安全', '改完即时生效')

        Column({ space: 16 }) {
          Row() {
            this.SettingRow('使用 HTTPS', '关闭后以明文传输，与不支持 https 的设备互通时使用')
            Toggle({ type: ToggleType.Switch, isOn: this.httpsOn })
              .onChange((on: boolean) => {
                this.httpsOn = on;
              })
          }
          .width('100%')

          Row() {
            this.SettingRow('自动接收', '开启后不再逐次询问，直接接收全部文件')
            Toggle({ type: ToggleType.Switch, isOn: this.autoAccept })
              .onChange((on: boolean) => {
                this.autoAccept = on;
              })
          }
          .width('100%')

          Column({ space: 8 }) {
            Text('接收 PIN 码').fontSize(13).fontColor(TEXT)
            TextInput({ text: this.pin, placeholder: '留空 = 不启用' })
              .type(InputType.Password)
              .onChange((v: string) => {
                this.pin = v;
              })
              .backgroundColor('#F7F8FA')
              .borderRadius(8)
            Text('设置后，对方发送前必须输入相同 PIN').fontSize(11).fontColor(SUB)
          }
          .alignItems(HorizontalAlign.Start)
          .width('100%')
        }
        .padding(16)
        .backgroundColor(CARD)
        .borderRadius(12)
        .border({ width: 1, color: LINE })
        .width('100%')

        Button('保存并重启服务')
          .width('100%')
          .height(40)
          .backgroundColor(GREEN)
          .borderRadius(10)
          .onClick(() => {
            this.applySettings();
          })

        Text(`当前服务：${this.serverState}`).fontSize(11).fontColor(SUB).width('100%')
        Text('快传鸿蒙版 v1.0.0 · 协议 LocalSend v2.2').fontSize(11).fontColor(SUB).width('100%')
      }
      .padding(16)
      .width('100%')
    }
    .backgroundColor(BG)
    .width('100%')
    .height('100%')
  }

  /** 保存设置并重启服务（HTTPS 开关、端口变更必须重启监听才生效） */
  private applySettings(): void {
    settingsService.save((s: Settings) => {
      s.alias = this.alias;
      s.https = this.httpsOn;
      s.pin = this.pin;
      s.autoAccept = this.autoAccept;
    });
    this.refreshLocal();

    httpServer.stop().then(() => {
      httpServer.start().then(() => {
        this.refreshLocal();
        Log.i('服务已按新设置重启');
      });
    });
    discoveryService.announce();
  }

  build() {
    Column() {
      Row() {
        Text('快传').fontSize(22).fontWeight(FontWeight.Medium).fontColor(TEXT)
        Blank()
        Text(this.devices.length > 0 ? `${this.devices.length} 台在线` : '搜索中…')
          .fontSize(12).fontColor(SUB)
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 12, bottom: 8 })

      Tabs({ barPosition: BarPosition.End, index: this.currentTab }) {
        TabContent() {
          this.ReceiveTab()
        }.tabBar('接收')

        TabContent() {
          this.SendTab()
        }.tabBar('发送')

        TabContent() {
          this.HistoryTab()
        }.tabBar('历史')

        TabContent() {
          this.SettingsTab()
        }.tabBar('设置')
      }
      .onChange((index: number) => {
        this.currentTab = index;
        if (index === 0 || index === 1) {
          this.refreshLocal();
        }
      })
      .barMode(BarMode.Fixed)
      .layoutWeight(1)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(BG)
  }
}
