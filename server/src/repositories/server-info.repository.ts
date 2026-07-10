import { Injectable } from '@nestjs/common';
import { exiftool } from 'exiftool-vendored';
import { exec as execCallback } from 'node:child_process';
import { readFile } from 'node:fs/promises';
import { promisify } from 'node:util';
import sharp from 'sharp';
import { ReleaseChannel } from 'src/dtos/system-config.dto';
import { ConfigRepository } from 'src/repositories/config.repository';
import { LoggingRepository } from 'src/repositories/logging.repository';

export interface GitHubRelease {
  id: number;
  url: string;
  tag_name: string;
  name: string;
  created_at: string;
  published_at: string;
  body: string;
  draft: boolean;
  prerelease: boolean;
}

export interface VersionResponse {
  version: string;
  published_at: string;
}

export interface ServerBuildVersions {
  nodejs: string;
  ffmpeg: string;
  libvips: string;
  exiftool: string;
  imagemagick: string;
}

const exec = promisify(execCallback);
const maybeFirstLine = async (command: string): Promise<string> => {
  try {
    const { stdout } = await exec(command);
    return stdout.trim().split('\n')[0] || '';
  } catch {
    return '';
  }
};

type BuildLockfile = {
  sources: Array<{ name: string; version: string }>;
  packages: Array<{ name: string; version: string }>;
};

const getLockfileVersion = (name: string, lockfile?: BuildLockfile) => {
  if (!lockfile) {
    return;
  }

  const items = [...(lockfile.sources || []), ...(lockfile?.packages || [])];
  const item = items.find((item) => item.name === name);
  return item?.version;
};

@Injectable()
export class ServerInfoRepository {
  constructor(
    private configRepository: ConfigRepository,
    private logger: LoggingRepository,
  ) {
    this.logger.setContext(ServerInfoRepository.name);
  }

  async getLatestRelease(channel: ReleaseChannel): Promise<VersionResponse> {
    try {
      const { versionCheck } = this.configRepository.getEnv();
      if (versionCheck.repository) {
        return await this.getLatestGitHubRelease(versionCheck.repository, channel);
      }

      const url = new URL(versionCheck.url);
      switch (channel) {
        case ReleaseChannel.Stable: {
          url.searchParams.append('channel', 'stable');
          break;
        }
        case ReleaseChannel.ReleaseCandidate: {
          url.searchParams.append('channel', 'rc');
          break;
        }
      }
      const response = await fetch(url);

      if (!response.ok) {
        throw new Error(`Version check request failed with status ${response.status}: ${await response.text()}`);
      }

      return response.json();
    } catch (error) {
      throw new Error('Failed to fetch latest release', { cause: error });
    }
  }

  private async getLatestGitHubRelease(repository: string, channel: ReleaseChannel): Promise<VersionResponse> {
    const endpoint = `https://api.github.com/repos/${repository}/releases`;
    const url = channel === ReleaseChannel.Stable ? `${endpoint}/latest` : endpoint;
    const response = await fetch(url);

    if (!response.ok) {
      throw new Error(`GitHub release request failed with status ${response.status}: ${await response.text()}`);
    }

    let release: GitHubRelease | undefined;
    if (channel === ReleaseChannel.Stable) {
      release = await response.json();
    } else {
      const releases: GitHubRelease[] = await response.json();
      release =
        releases.find((release) => release.prerelease && !release.draft) ?? releases.find((release) => !release.draft);
    }

    if (!release) {
      throw new Error(`No published GitHub release found for ${repository}`);
    }

    return { version: release.tag_name, published_at: release.published_at };
  }

  buildVersions?: ServerBuildVersions;

  private async retrieveVersionFallback(
    command: string,
    commandTransform?: (output: string) => string,
    version?: string,
  ): Promise<string> {
    if (!version) {
      const output = await maybeFirstLine(command);
      version = commandTransform ? commandTransform(output) : output;
    }
    return version;
  }

  async getBuildVersions(): Promise<ServerBuildVersions> {
    if (!this.buildVersions) {
      const { nodeVersion, resourcePaths } = this.configRepository.getEnv();

      const lockfile: BuildLockfile | undefined = await readFile(resourcePaths.lockFile)
        .then((buffer) => JSON.parse(buffer.toString()))
        .catch(() => this.logger.warn(`Failed to read ${resourcePaths.lockFile}`));

      const [nodejsVersion, ffmpegVersion, magickVersion, exiftoolVersion] = await Promise.all([
        this.retrieveVersionFallback('node --version', undefined, nodeVersion),
        this.retrieveVersionFallback(
          'ffmpeg -version',
          (output) => output.replaceAll('ffmpeg version ', ''),
          getLockfileVersion('ffmpeg', lockfile),
        ),
        this.retrieveVersionFallback(
          'magick --version',
          (output) => output.replaceAll('Version: ImageMagick ', ''),
          getLockfileVersion('imagemagick', lockfile),
        ),
        exiftool.version(),
      ]);

      const libvipsVersion = getLockfileVersion('libvips', lockfile) || sharp.versions.vips;

      this.buildVersions = {
        nodejs: nodejsVersion,
        exiftool: exiftoolVersion,
        ffmpeg: ffmpegVersion,
        libvips: libvipsVersion,
        imagemagick: magickVersion,
      };
    }

    return this.buildVersions;
  }
}
