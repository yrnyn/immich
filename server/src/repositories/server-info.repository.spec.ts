import { ReleaseChannel } from 'src/dtos/system-config.dto';
import { LoggingRepository } from 'src/repositories/logging.repository';
import { ServerInfoRepository } from 'src/repositories/server-info.repository';
import { mockEnvData, newConfigRepositoryMock } from 'test/repositories/config.repository.mock';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

describe(ServerInfoRepository.name, () => {
  const fetchMock = vi.fn();
  const config = newConfigRepositoryMock();
  const logger = { setContext: vi.fn() } as unknown as LoggingRepository;
  let sut: ServerInfoRepository;

  beforeEach(() => {
    sut = new ServerInfoRepository(config, logger);
    vi.stubGlobal('fetch', fetchMock);
  });

  afterEach(() => {
    vi.unstubAllGlobals();
    vi.clearAllMocks();
  });

  it('should retrieve the latest release from the configured GitHub repository', async () => {
    config.getEnv.mockReturnValue(
      mockEnvData({
        versionCheck: {
          url: 'https://version.immich.cloud/version',
          repository: 'yrnyn/immich',
        },
      }),
    );
    fetchMock.mockResolvedValue({
      ok: true,
      json: () => Promise.resolve({ tag_name: 'v3.0.3-tz-null-fix', published_at: '2026-07-10T00:00:00Z' }),
    });

    await expect(sut.getLatestRelease(ReleaseChannel.Stable)).resolves.toEqual({
      version: 'v3.0.3-tz-null-fix',
      published_at: '2026-07-10T00:00:00Z',
    });
    expect(fetchMock).toHaveBeenCalledWith('https://api.github.com/repos/yrnyn/immich/releases/latest');
  });
});
