import {
  Button,
  HStack,
  List,
  Picker,
  Section,
  SecureField,
  Spacer,
  Text,
  TextField,
  Toggle,
  VStack,
} from "scripting"

import { SCRIPT_VERSION, type Config } from "../utils/config"
import { DEFAULT_REPO, type ReleaseInfo } from "../utils/github"
import { BACKUP_DIR, type BackupEntry } from "../utils/install"
import type { SyncFile } from "../utils/sync_service"

function KvRow(props: { label: string; value: string; color?: string }) {
  return (
    <HStack>
      <Text>{props.label}</Text>
      <Spacer />
      <Text foregroundStyle={props.color ?? "secondaryLabel"}>
        {props.value}
      </Text>
    </HStack>
  )
}

function formatTime(value: string): string {
  if (!value) return ""
  const date = new Date(value)
  if (isNaN(date.getTime())) return value
  const two = (n: number) => String(n).padStart(2, "0")
  return (
    `${date.getFullYear()}-${two(date.getMonth() + 1)}-${two(date.getDate())} ` +
    `${two(date.getHours())}:${two(date.getMinutes())}`
  )
}

type CloudRow = {
  key: string
  title: string
  detail: string
  files: SyncFile[]
}

/** 把云端文件按路径分组：`*.userdb` 目录下的文件合并成一组，与桌面端行为一致。 */
function groupCloudFiles(files: SyncFile[]): CloudRow[] {
  const groups = new Map<string, CloudRow>()
  const order: string[] = []
  for (const file of files) {
    const marker = file.path.indexOf(".userdb/")
    const key = marker < 0 ? file.path : file.path.slice(0, marker + ".userdb".length)
    const existing = groups.get(key)
    if (existing) {
      existing.files.push(file)
    } else {
      groups.set(key, { key, title: key, detail: "", files: [file] })
      order.push(key)
    }
  }
  return order.map((key) => {
    const row = groups.get(key)!
    const by = row.files[0].by_name || row.files[0].by
    row.title =
      row.files.length > 1 ? `${key}（${row.files.length} 个文件）` : key
    row.detail = `${by} · ${formatTime(row.files[0].at)}`
    return row
  })
}

/** 云同步：WebDAV 配置、上传下载、同步库文件管理。 */
export function CloudSyncPage(props: {
  busy: boolean
  hasDir: boolean
  config: Config
  password: string
  cloudFiles: SyncFile[]
  cloudDevices: number
  onConfigChange: (next: Config) => void
  onPasswordChange: (value: string) => void
  onSave: () => void
  onUpload: () => void
  onDownload: () => void
  onRefresh: () => void
  onDeleteFiles: (files: SyncFile[]) => void
}) {
  const rows = groupCloudFiles(props.cloudFiles)
  return (
    <List
      navigationTitle="云同步"
      navigationBarTitleDisplayMode="inline"
      listStyle="insetGroup"
    >
      <Section header={<Text>WebDAV 配置</Text>}>
        <TextField
          title="服务器地址"
          value={props.config.syncUrl}
          onChanged={(value: string) =>
            props.onConfigChange({ ...props.config, syncUrl: value })
          }
        />
        <TextField
          title="用户名"
          value={props.config.syncUser}
          onChanged={(value: string) =>
            props.onConfigChange({ ...props.config, syncUser: value })
          }
        />
        <SecureField
          title="密码 / 应用密码"
          value={props.password}
          onChanged={props.onPasswordChange}
        />
        <TextField
          title="本机名称"
          value={props.config.deviceName}
          onChanged={(value: string) =>
            props.onConfigChange({ ...props.config, deviceName: value })
          }
        />
        <Button title="保存配置" action={props.onSave} disabled={props.busy} />
      </Section>

      <Section header={<Text>同步</Text>}>
        <HStack spacing={8}>
          <Button
            title="上传本机"
            action={props.onUpload}
            disabled={props.busy || !props.hasDir}
          />
          <Button
            title="下载云端"
            action={props.onDownload}
            disabled={props.busy || !props.hasDir}
          />
        </HStack>
        <Button
          title="刷新云端清单"
          action={props.onRefresh}
          disabled={props.busy}
        />
      </Section>

      <Section
        header={<Text>同步库</Text>}
        footer={
          <Text>
            {`按当前目录的前端共用一个同步库，覆盖本机前会先备份个人数据。`}
          </Text>
        }
      >
        <KvRow
          label="云端文件"
          value={`${props.cloudFiles.length} 个 · ${props.cloudDevices} 台设备`}
        />
        {rows.length === 0 ? (
          <Text font="caption" foregroundStyle="secondaryLabel">
            还没有云端文件。填好地址后先「上传本机」。
          </Text>
        ) : null}
        {rows.map((row) => (
          <VStack key={row.key} spacing={2} alignment="leading">
            <HStack>
              <Text font="footnote">{row.title}</Text>
              <Spacer />
              <Button
                title="删除"
                role="destructive"
                action={() => props.onDeleteFiles(row.files)}
                disabled={props.busy}
              />
            </HStack>
            <Text font="caption" foregroundStyle="secondaryLabel">
              {row.detail}
            </Text>
          </VStack>
        ))}
      </Section>
    </List>
  )
}

/** 备份与回滚：当前目录的快照列表。 */
export function BackupsPage(props: {
  busy: boolean
  hasDir: boolean
  backups: BackupEntry[]
  onRollback: (entry: BackupEntry) => void
  onDelete: (entry: BackupEntry) => void
  onRefresh: () => void
}) {
  return (
    <List
      navigationTitle="备份与回滚"
      navigationBarTitleDisplayMode="inline"
      listStyle="insetGroup"
    >
      <Section
        header={<Text>快照</Text>}
        footer={<Text>回滚会把快照里的文件写回当前目录，并自动请求部署。</Text>}
      >
        {props.backups.length === 0 ? (
          <Text font="caption" foregroundStyle="secondaryLabel">
            {props.hasDir
              ? "还没有快照。更新或从本地 zip 安装后会自动生成。"
              : "先回到主页添加一个 Rime 用户目录。"}
          </Text>
        ) : null}
        {props.backups.map((entry) => (
          <VStack key={entry.name} spacing={2} alignment="leading">
            <HStack>
              <Text>{entry.name}</Text>
              <Spacer />
              <Button
                title="回滚"
                action={() => props.onRollback(entry)}
                disabled={props.busy}
              />
              <Button
                title="删除"
                role="destructive"
                action={() => props.onDelete(entry)}
                disabled={props.busy}
              />
            </HStack>
            <Text font="caption" foregroundStyle="secondaryLabel">
              {`${entry.version ? `v${entry.version} · ` : ""}${entry.files} 个文件`}
            </Text>
          </VStack>
        ))}
        <Button
          title="刷新备份列表"
          action={props.onRefresh}
          disabled={props.busy || !props.hasDir}
        />
      </Section>
    </List>
  )
}

/** 换方案：清空旧方案运行文件后安装新包，个人数据自动备份恢复。 */
export function SwitchSchemePage(props: {
  busy: boolean
  hasDir: boolean
  activeDirName: string
  inputMethodLabel: string
  repo: string
  onLocalZip: () => void
  onRelease: () => void
}) {
  return (
    <List
      navigationTitle="换方案"
      navigationBarTitleDisplayMode="inline"
      listStyle="insetGroup"
    >
      <Section
        header={<Text>换方案</Text>}
        footer={
          <Text>
            先备份个人数据（词库、自造词、开关记忆），再清掉旧方案的运行文件，安装新方案后把个人数据补回去，最后请求部署。
          </Text>
        }
      >
        <KvRow
          label="目标目录"
          value={props.hasDir ? props.activeDirName : "未选择"}
        />
        <KvRow label="部署方式" value={props.inputMethodLabel} />
        <Button
          title="从本地 zip 换方案"
          action={props.onLocalZip}
          disabled={props.busy || !props.hasDir}
        />
        <Button
          title={`从 ${props.repo} 换方案`}
          action={props.onRelease}
          disabled={props.busy || !props.hasDir}
        />
      </Section>
    </List>
  )
}

/** 设置：更新来源（仓库、安装包）、通用开关、Token 与关于信息。 */
export function SettingsPage(props: {
  busy: boolean
  config: Config
  remote: ReleaseInfo | null
  onUpdate: (next: Config) => void
  onEditToken: () => void
  onEditRepo: () => void
  onResetRepo: () => void
  onPickAsset: (name: string) => void
  selfUpdateLabel: string
  onCheckSelfUpdate: () => void
}) {
  const config = props.config
  return (
    <List
      navigationTitle="设置"
      navigationBarTitleDisplayMode="inline"
      listStyle="insetGroup"
    >
      <Section header={<Text>更新来源</Text>}>
        <KvRow label="仓库" value={config.repo} />
        <HStack spacing={8}>
          <Button title="修改仓库" action={props.onEditRepo} disabled={props.busy} />
          <Button
            title="恢复默认"
            action={props.onResetRepo}
            disabled={
              props.busy ||
              (config.repo === DEFAULT_REPO && !config.assetName)
            }
          />
        </HStack>
      </Section>

      <Section
        header={<Text>安装包</Text>}
        footer={
          <Text>
            {props.remote
              ? "「自动选择」优先增量包，模型大变更时会提示改用完整包。"
              : "回主页「检查更新」后可以在这里指定要用的安装包。"}
          </Text>
        }
      >
        {props.remote && props.remote.assets.length > 1 ? (
          <Picker
            title="安装包"
            value={config.assetName}
            onChanged={(value: string) => props.onPickAsset(value)}
            pickerStyle="menu"
          >
            <Text tag="">自动选择（优先增量包）</Text>
            {props.remote.assets.map((asset) => (
              <Text key={asset.name} tag={asset.name}>
                {asset.name}
              </Text>
            ))}
          </Picker>
        ) : (
          <KvRow
            label="当前选择"
            value={config.assetName || "自动选择（优先增量包）"}
          />
        )}
      </Section>

      <Section header={<Text>通用</Text>}>
        <Toggle
          title="启动时自动检查"
          value={config.autoCheckOnLaunch}
          onChanged={(value: boolean) =>
            props.onUpdate({ ...config, autoCheckOnLaunch: value })
          }
        />
        <Toggle
          title="显示详细日志"
          value={config.verboseLog}
          onChanged={(value: boolean) =>
            props.onUpdate({ ...config, verboseLog: value })
          }
        />
        <KvRow label="Token" value={config.token ? "已设置" : "未设置"} />
        <HStack spacing={8}>
          <Button title="设置 Token" action={props.onEditToken} />
          <Button
            title="清除 Token"
            role="destructive"
            action={() => props.onUpdate({ ...config, token: "" })}
            disabled={!config.token}
          />
        </HStack>
      </Section>

      <Section header={<Text>关于</Text>}>
        <KvRow label="脚本版本" value={SCRIPT_VERSION} />
        <KvRow label="快照目录" value={BACKUP_DIR} />
        <Button
          title={props.busy ? "检查中…" : "检查脚本更新"}
          systemImage="arrow.triangle.2.circlepath"
          action={props.onCheckSelfUpdate}
          disabled={props.busy}
        />
        {props.selfUpdateLabel ? (
          <Text font="caption" foregroundStyle="secondaryLabel">
            {props.selfUpdateLabel}
          </Text>
        ) : null}
      </Section>
    </List>
  )
}

/** 日志：完整日志尾部、清空与详细开关。 */
export function LogPage(props: {
  log: string
  verbose: boolean
  filesCount: number
  hasDir: boolean
  onToggleVerbose: (value: boolean) => void
  onClear: () => void
}) {
  const tail = props.log.split("\n").slice(-100).join("\n")
  return (
    <List
      navigationTitle="日志"
      navigationBarTitleDisplayMode="inline"
      listStyle="insetGroup"
    >
      <Section>
        <Toggle
          title="显示详细日志"
          value={props.verbose}
          onChanged={props.onToggleVerbose}
        />
        <Button title="清空日志" action={props.onClear} />
      </Section>
      <Section header={<Text>最近日志</Text>}>
        {props.verbose ? (
          <Text font="caption" foregroundStyle="secondaryLabel">
            {tail || "等待操作"}
          </Text>
        ) : (
          <Text font="caption" foregroundStyle="secondaryLabel">
            已关闭详细日志
          </Text>
        )}
        {props.hasDir ? (
          <Text font="caption" foregroundStyle="secondaryLabel">
            {`目录内 ${props.filesCount} 项`}
          </Text>
        ) : null}
      </Section>
    </List>
  )
}

export { KvRow }
